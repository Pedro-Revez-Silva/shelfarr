# frozen_string_literal: true

module Kobo
  # Private, bounded cache of DRM-free copies of Kobo account purchases.
  #
  # Layout: <root>/<account id>/<catalogue entry id>/<sha256>.epub, plus an
  # <root>/.incoming directory for partial downloads. Directories are 0700 and
  # files 0600. Paths derive only from database ids and the content digest, so
  # nothing a provider sends can select a path. A download is written to a new
  # exclusive temporary file, checked for its full declared size and validated
  # as an unencrypted EPUB before an atomic rename promotes it. Failures never
  # touch a copy that is already ready. Copies referenced by a delivery are
  # pinned: they are never evicted while a reader may still fetch them.
  #
  # Capacity: ready copies plus every in-flight reservation stay within
  # max_total_bytes. A reservation is a <random>.lease file beside its
  # <random>.part, flock-held by the worker from reservation until its partial
  # bytes are gone. The kernel drops that lock when the worker dies, however it
  # dies, so a lease nobody holds marks an abandoned attempt whatever its age,
  # and a held lease keeps counting even after its row was timed out or
  # deleted. Reservations, reclamation and promotion take one short
  # cross-process lock, never held during network transfer.
  class BookCache
    MAX_TOTAL_BYTES = 4.gigabytes
    PER_USER_HOURLY = 20
    INCOMING = ".incoming"
    LEASE = ".lease"
    PART = ".part"
    LEASE_NAME = /\A[0-9a-f]{32}\.lease\z/
    PART_NAME = /\A[0-9a-f]{32}\.part\z/
    class Failure < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    class << self
      def root
        Pathname(ENV["KOBO_ACCOUNT_CACHE_PATH"].presence || Rails.root.join("storage", "kobo_account_cache")).expand_path
      end

      def max_total_bytes
        value = Integer(ENV["KOBO_ACCOUNT_CACHE_MAX_BYTES"].to_s, 10, exception: false)
        value&.positive? ? value : MAX_TOTAL_BYTES
      end

      # Called from the web UI by the owner or a recipient. The fetch runs in a
      # job; the returned row is the in-progress (or already running) attempt.
      def request!(book, viewer)
        HouseholdAccess.grant!(viewer, book.kobo_account)
        raise Failure, "not_eligible" unless book.deliverable?
        raise Failure, "reauthorization_required" unless book.kobo_account.connected?

        row = book.with_lock do
          next book.active_fetch if book.active_fetch

          book.kobo_account_book_files.where(status: "fetching").update_all(status: "failed", error: "timed_out", updated_at: Time.current)
          if KoboAccountBookFile.where(requested_by_id: viewer.id, created_at: 1.hour.ago..).count >= PER_USER_HOURLY
            raise Failure, "rate_limited"
          end

          book.kobo_account_book_files.create!(status: "fetching", request_id: SecureRandom.uuid,
            requested_by: viewer, started_at: Time.current)
        end
        enqueue(row) if row.previously_new_record?
        row
      end

      # Opens a ready copy pinned to the device and inode recorded at promotion.
      def open(row)
        unless row&.ready? && row.storage_key.to_s.match?(KoboAccountBookFile::STORAGE_KEY)
          raise KoboPublication::Unavailable, "The shared copy is not ready"
        end

        file = FileCopyService.open_pinned_regular_file(root.join(row.storage_key).to_s, root: root.to_s,
          expected_device: Integer(row.file_device), expected_inode: Integer(row.file_inode))
        unless file.stat.size == row.size_bytes
          file.close
          raise KoboPublication::Unavailable, "The shared copy changed"
        end
        file
      rescue FileCopyService::UnsafePathError, SystemCallError, ArgumentError, TypeError
        raise KoboPublication::Unavailable, "The shared copy is missing"
      end

      def remove(storage_key)
        return unless storage_key.to_s.match?(KoboAccountBookFile::STORAGE_KEY)

        path = root.join(storage_key)
        File.unlink(path) if File.lstat(path).file?
        [ path.dirname, path.dirname.dirname ].each do |directory|
          Dir.rmdir(directory)
        rescue SystemCallError
          break
        end
      rescue SystemCallError => error
        Rails.logger.info("[Kobo] A cached copy was already gone (#{error.class.name})")
      end

      private

      def enqueue(row)
        KoboBookFetchJob.perform_later(row.id, row.request_id) || raise(Failure, "queue_unavailable")
      rescue StandardError => error
        Rails.logger.warn("[Kobo] Copy enqueue failed (#{error.class.name})")
        row.update!(status: "failed", error: "queue_unavailable")
      end
    end

    def initialize(row, locator: nil, downloader: BookDownload.new)
      @row = row
      @book = row.kobo_account_book
      @account = @book.kobo_account
      @locator = locator || DownloadLocator.new(@account)
      @downloader = downloader
    end

    def call
      authorize!
      located = @locator.call(@book)
      raise Failure, "not_eligible" unless located&.purchased && located.choice.rights == "drm_free"

      reserve_capacity!(located.choice.size || BookDownload::MAX_BYTES)
      promote(download(located.choice), located)
    rescue Failure, BookDownload::Error => error
      fail!(error.code)
    rescue HttpClient::Error => error
      if error.code == "credentials_expired"
        mark_reauthorization
        fail!("reauthorization_required")
      else
        fail!(error.code == "catalogue_limit" ? "protocol_changed" : error.code)
      end
    rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
      Rails.logger.info("[Kobo] Discarded an outdated copy result")
      fail!("provider_unavailable")
    rescue Errno::ENOSPC, Errno::EDQUOT
      fail!("storage_full")
    ensure
      release_lease
    end

    private

    def root
      self.class.root
    end

    # The requester must still hold access and the title must still qualify.
    def authorize!
      raise Failure, "access_revoked" unless @row.requested_by && HouseholdAccess.grant(@row.requested_by, @account)
      raise Failure, "not_eligible" unless @book.reload.deliverable?
      raise Failure, "reauthorization_required" unless @account.reload.connected?
    end

    def download(choice)
      path = @temporary_path
      flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      @result = File.open(path, flags, 0o600, binmode: true) do |io|
        @downloader.call(choice.url, io: io, expected_size: choice.size).tap do
          io.flush
          io.fsync
        end
      end
      File.open(path, File::RDONLY | File::NOFOLLOW, binmode: true) do |file|
        raise Failure, "incomplete" unless file.stat.file? && file.stat.size == @result.bytes
        raise Failure, "too_large" if @result.bytes > BookDownload::MAX_BYTES

        @epub_version = KoboPublication.validate_file(file)
      end
      path
    rescue KoboPublication::Encrypted
      raise Failure, "protected_file"
    rescue KoboPublication::Unavailable
      raise Failure, "invalid_file"
    ensure
      File.unlink(path) if path && @epub_version.nil? && File.exist?(path)
    end

    # Promotion holds the capacity lock, so reclamation never sees a renamed
    # file before its row commits, and two promotions of the same bytes cannot
    # replace each other's file. A worker that dies between the rename and the
    # commit leaves an unreferenced file the next reclamation removes.
    def promote(temporary, located)
      key = "#{@account.id}/#{@book.id}/#{@result.sha256}.epub"
      with_capacity_lock do
        final = private_directory(root.join(@account.id.to_s, @book.id.to_s)).join("#{@result.sha256}.epub")
        if File.exist?(final)
          # The same bytes are already cached: keep that file and drop ours.
          raise Failure, "incomplete" unless File.lstat(final).file? && File.size(final) == @result.bytes

          File.unlink(temporary)
        else
          File.rename(temporary, final)
        end
        stat = File.lstat(final)
        KoboAccountBookFile.transaction do
          @row.reload
          raise ActiveRecord::StaleObjectError unless @row.status == "fetching"

          authorize!
          @row.update!(status: "ready", error: nil, storage_key: key, sha256: @result.sha256, size_bytes: @result.bytes,
            expected_size: located.choice.size, format: located.choice.format, kobo_revision_id: located.revision_id || @book.revision_id,
            epub_version: @epub_version.to_s.first(16), file_device: stat.dev.to_s, file_inode: stat.ino.to_s,
            fetched_at: Time.current, last_used_at: Time.current)
        end
      rescue StandardError
        self.class.remove(key) unless KoboAccountBookFile.where(storage_key: key, status: "ready").exists?
        raise
      end
      prune
      @row
    end

    # Older ready copies of this title that no delivery references are
    # superseded, as are earlier failures.
    def prune
      @book.kobo_account_book_files.where(status: %w[ready failed]).where.not(id: @row.id)
        .where.not(id: KoboDelivery.where.not(kobo_account_book_file_id: nil).select(:kobo_account_book_file_id))
        .find_each(&:destroy!)
    end

    # Reserve before writing bytes: every increase in ready + in-flight bytes
    # passes here, after abandoned attempts are reclaimed. The lease is taken
    # inside the lock, before any partial byte exists.
    def reserve_capacity!(needed)
      with_capacity_lock do
        @row.reload
        raise ActiveRecord::StaleObjectError unless @row.status == "fetching"

        @in_flight_bytes = reclaim_abandoned
        ensure_capacity!(needed)
        take_lease(needed)
        @row.update!(expected_size: needed)
      end
    end

    def with_capacity_lock
      private_directory(root)
      File.open(root.join(".capacity.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise Failure, "storage_full" unless lock.stat.file? && lock.flock(File::LOCK_EX)

        yield
      end
    end

    def take_lease(needed)
      incoming = private_directory(root.join(INCOMING))
      name = SecureRandom.hex(16)
      @lease_path = incoming.join("#{name}#{LEASE}")
      @lease = File.open(@lease_path, File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
      raise Failure, "storage_full" unless @lease.flock(File::LOCK_EX | File::LOCK_NB)

      # Only ids, a random request id and a byte count: never a URL or secret.
      @lease.write(JSON.generate("row" => @row.id, "request" => @row.request_id, "bytes" => needed))
      @lease.flush
      @temporary_path = incoming.join("#{name}#{PART}")
    end

    # The partial goes first: a reservation is released only once its bytes
    # are gone, so a crash in between leaves a lease that is reclaimed later.
    def release_lease
      File.unlink(@temporary_path) if @temporary_path && File.exist?(@temporary_path)
      File.unlink(@lease_path) if @lease_path && File.exist?(@lease_path)
    rescue SystemCallError => error
      Rails.logger.warn("[Kobo] Could not release a copy reservation (#{error.class.name})")
    ensure
      @lease&.close
      @lease = nil
    end

    def ensure_capacity!(needed)
      maximum = self.class.max_total_bytes
      raise Failure, "too_large" if needed > maximum

      return if used_bytes + needed <= maximum

      pinned = KoboDelivery.where.not(kobo_account_book_file_id: nil).select(:kobo_account_book_file_id)
      # Every in-progress replacement keeps its previous valid copy, including
      # against another title's concurrent eviction and before it is delivered.
      replacing = KoboAccountBookFile.where(status: "fetching").select(:kobo_account_book_id)
      KoboAccountBookFile.where(status: "ready").where.not(id: pinned).where.not(kobo_account_book_id: replacing)
        .order(Arel.sql("COALESCE(last_used_at, fetched_at) ASC"), :id).each do |candidate|
        candidate.destroy!
        return if used_bytes + needed <= maximum
      end
      raise Failure, "cache_full"
    end

    # Identical ready copies share one on-disk file. In-flight bytes come from
    # live leases, not row status, so they survive a timed-out or deleted row.
    def used_bytes
      KoboAccountBookFile.where(status: "ready").pluck(:storage_key, :size_bytes).to_h.values.sum(&:to_i) + @in_flight_bytes
    end

    # Under the capacity lock: removes what dead workers left behind and
    # returns the bytes live workers hold (their reservation, or their partial
    # if larger). No new lease or promotion can start meanwhile.
    def reclaim_abandoned
      incoming = private_directory(root.join(INCOMING))
      held = Dir.children(incoming).sort.sum do |name|
        next 0 unless name.match?(LEASE_NAME)

        inspect_lease(incoming.join(name))
      end
      # A partial whose lease is gone has no live writer: leases precede their
      # partials and are released only after them.
      Dir.each_child(incoming) do |name|
        next unless name.match?(PART_NAME) && !File.exist?(incoming.join(name.delete_suffix(PART) + LEASE))

        unlink_regular(incoming.join(name))
      end
      reclaim_unreferenced_copies
      held
    end

    def inspect_lease(path)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |lease|
        next 0 unless lease.stat.file?

        details = lease_details(lease)
        partial = Pathname(path.to_s.delete_suffix(LEASE) + PART)
        if lease.flock(File::LOCK_EX | File::LOCK_NB)
          abandon(details, partial, path)
          0
        else
          reserved = Integer(details["bytes"], exception: false)
          [ reserved&.positive? ? reserved : BookDownload::MAX_BYTES, regular_size(partial) ].max
        end
      end
    rescue SystemCallError
      0
    end

    def lease_details(lease)
      details = JSON.parse(lease.read(4.kilobytes).to_s)
      details.is_a?(Hash) ? details : {}
    rescue JSON::ParserError
      {}
    end

    # The worker is gone: drop its partial, then record the attempt as failed
    # so its title no longer waits on it, then release the reservation.
    def abandon(details, partial, lease_path)
      unlink_regular(partial)
      if (id = Integer(details["row"], exception: false)) && details["request"].is_a?(String)
        KoboAccountBookFile.where(id: id, request_id: details["request"], status: "fetching")
          .update_all([ "status = 'failed', error = 'incomplete', lock_version = lock_version + 1, updated_at = ?", Time.current ])
      end
      File.unlink(lease_path)
      Rails.logger.info("[Kobo] Reclaimed an abandoned copy attempt")
    end

    # Final files no row names, such as one renamed into place by a worker
    # that died before recording it.
    def reclaim_unreferenced_copies
      referenced = KoboAccountBookFile.where.not(storage_key: nil).distinct.pluck(:storage_key).to_set
      stored_keys.each { |key| self.class.remove(key) unless referenced.include?(key) }
    end

    def stored_keys
      id_directories(root).flat_map do |account|
        id_directories(root.join(account)).flat_map do |book|
          entries(root.join(account, book)).filter_map do |name|
            "#{account}/#{book}/#{name}" if name.match?(/\A[0-9a-f]{64}\.epub\z/) && regular?(root.join(account, book, name))
          end
        end
      end
    end

    # Numeric account or title directories, never following a symlink.
    def id_directories(path)
      entries(path).select { |name| name.match?(/\A\d{1,19}\z/) && File.directory?(path.join(name)) && !File.symlink?(path.join(name)) }
    end

    # Dir.glob returns nothing for a directory removed meanwhile.
    def entries(path)
      Dir.glob("*", base: path.to_s)
    end

    def regular?(path)
      File.file?(path) && !File.symlink?(path)
    end

    def regular_size(path)
      regular?(path) ? File.size(path) : 0
    rescue SystemCallError
      0
    end

    def unlink_regular(path)
      File.unlink(path) if regular?(path)
    rescue SystemCallError => error
      Rails.logger.info("[Kobo] A reclaimed partial was already gone (#{error.class.name})")
    end

    def private_directory(path)
      relative = path.relative_path_from(root)
      raise Failure, "storage_full" if relative.to_s.start_with?("..")

      FileUtils.mkdir_p(root, mode: 0o700)
      current = root
      [ root, *relative.each_filename.map { |part| current = current.join(part) } ].each do |directory|
        Dir.mkdir(directory, 0o700) unless File.exist?(directory)
        stat = File.lstat(directory)
        raise Failure, "storage_full" unless stat.directory? && !stat.symlink?
      end
      path
    end

    def fail!(code)
      File.unlink(@temporary_path) if @temporary_path && File.exist?(@temporary_path)
      code = "protocol_changed" unless KoboAccountBookFile::ERROR_MESSAGES.key?(code)
      @row.reload
      @row.update!(status: "failed", error: code) if @row.status == "fetching"
    rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
      Rails.logger.info("[Kobo] Discarded an outdated copy failure")
    end

    def mark_reauthorization
      @account.reload.update!(status: "reauthorization_required", last_error: "credentials_expired")
    rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
      Rails.logger.info("[Kobo] Account changed before its sign-in state was recorded")
    end
  end
end
