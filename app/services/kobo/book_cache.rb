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
  class BookCache
    MAX_TOTAL_BYTES = 4.gigabytes
    PER_USER_HOURLY = 20
    INCOMING = ".incoming"
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

      ensure_capacity!(located.choice.size || BookDownload::MAX_BYTES)
      temporary = download(located.choice)
      promote(temporary, located)
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
      File.unlink(temporary) if temporary && File.exist?(temporary)
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
      incoming = private_directory(root.join(INCOMING))
      sweep(incoming)
      path = incoming.join("#{SecureRandom.hex(16)}.part")
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

    def promote(temporary, located)
      key = "#{@account.id}/#{@book.id}/#{@result.sha256}.epub"
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
      prune
      @row
    rescue Failure, ActiveRecord::StaleObjectError
      self.class.remove(key) unless KoboAccountBookFile.where(storage_key: key, status: "ready").exists?
      raise
    end

    # Older ready copies of this title that no delivery references are
    # superseded, as are earlier failures.
    def prune
      @book.kobo_account_book_files.where(status: %w[ready failed]).where.not(id: @row.id)
        .where.not(id: KoboDelivery.where.not(kobo_account_book_file_id: nil).select(:kobo_account_book_file_id))
        .find_each(&:destroy!)
    end

    def ensure_capacity!(needed)
      maximum = self.class.max_total_bytes
      raise Failure, "too_large" if needed > maximum

      used = -> { KoboAccountBookFile.where(status: "ready").distinct.pluck(:storage_key, :size_bytes).sum(&:last) }
      return if used.call + needed <= maximum

      pinned = KoboDelivery.where.not(kobo_account_book_file_id: nil).select(:kobo_account_book_file_id)
      KoboAccountBookFile.where(status: "ready").where.not(id: pinned)
        .order(Arel.sql("COALESCE(last_used_at, fetched_at) ASC"), :id).each do |candidate|
        candidate.destroy!
        return if used.call + needed <= maximum
      end
      raise Failure, "cache_full"
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

    # Partial files left by a crashed worker.
    def sweep(incoming)
      Dir.each_child(incoming) do |name|
        path = incoming.join(name)
        stat = File.lstat(path)
        File.unlink(path) if stat.file? && name.end_with?(".part") && stat.mtime < (KoboAccountBookFile::FETCH_LEASE * 2).ago
      rescue SystemCallError
        next
      end
    end

    def fail!(code)
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
