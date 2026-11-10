# frozen_string_literal: true

module Kobo
  # Persistent, bounded cache of Kobo editions (KEPUB) prepared from library
  # EPUB files by KepubConverter. Library files are only ever read.
  #
  # Layout: <root>/<sha[0,2]>/<sha256>.kepub.epub, plus <root>/.incoming for
  # partial output. Directories are 0700 and files 0600; paths derive only from
  # the copy's own digest. A copy is bound to the converter version and to the
  # SHA-256 of the exact source bytes. Its row is created only after the whole
  # copy was written, synced, verified against the source (see
  # KepubConverter.verify) and renamed into place, so a failure, a crash or a
  # full cache never replaces or removes a copy that is already ready.
  #
  # One cross-process lock covers preparation, rebuilding, eviction and
  # reclamation. A partial file seen while holding it belongs to a dead worker.
  # Copies referenced by a delivery, and copies used in the last hour (between
  # preparation and the delivery that will reference them), are never evicted.
  #
  # A copy lost from disk is rebuilt from its unchanged source only when the
  # result is byte-identical to what the reader was offered; otherwise the
  # reader must be sent the book again.
  class KepubCache
    MAX_TOTAL_BYTES = 2.gigabytes
    MAX_COPY_BYTES = KoboPublication::MAX_EPUB_BYTES + 64.megabytes
    LOCK_WAIT = 30 # seconds
    RECENT = 1.hour
    INCOMING = ".incoming"
    PART_NAME = /\A[0-9a-f]{32}\.part\z/
    COPY_NAME = /\A[0-9a-f]{64}\.kepub\.epub\z/

    # Preparing is not possible right now (cache full, disk full, busy). The
    # caller keeps whatever it delivered before.
    class Failure < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    # The delivered copy is briefly unavailable: another request holds the lock.
    class Busy < KoboPublication::Unavailable; end

    class << self
      attr_writer :lock_wait

      # Seconds to wait for another preparation; tests shorten it.
      def lock_wait
        @lock_wait || LOCK_WAIT
      end

      def root
        Pathname(ENV["KOBO_KEPUB_CACHE_PATH"].presence || Rails.root.join("storage", "kobo_kepub_cache")).expand_path
      end

      def max_total_bytes
        value = Integer(ENV["KOBO_KEPUB_CACHE_MAX_BYTES"].to_s, 10, exception: false)
        value&.positive? ? value : MAX_TOTAL_BYTES
      end

      # A ready copy of the open source generation, prepared if needed.
      def prepare(source)
        new.prepare(source)
      end

      # The copy's bytes, pinned to the file recorded at promotion.
      def open(copy, sha256:, source:)
        new.open(copy, sha256: sha256, source: source)
      end

      def sha256(file)
        digest = Digest::SHA256.new
        offset = 0
        while (chunk = file.pread(1.megabyte, offset)) && !chunk.empty?
          digest << chunk
          offset += chunk.bytesize
        end
        digest.hexdigest
      rescue EOFError
        digest.hexdigest
      end

      def changed_at(stat)
        "#{stat.ctime.to_i}.#{stat.ctime.nsec}"
      end

      def sha256_path(path)
        File.open(path, File::RDONLY | File::NOFOLLOW, binmode: true) { |file| sha256(file) }
      end
    end

    def prepare(source)
      digest = self.class.sha256(source)
      with_lock do
        reclaim
        ready = KoboKepubCopy.where(converter: KepubConverter::VERSION, source_sha256: digest).order(id: :desc).find { |copy| present?(copy) }
        next touch(ready) if ready

        build(source, digest)
      end
    rescue Errno::ENOSPC, Errno::EDQUOT
      raise Failure, "storage_full"
    rescue SystemCallError, FileCopyService::UnsafePathError
      raise Failure, "storage_unavailable"
    end

    def open(copy, sha256:, source:)
      raise KoboPublication::Unavailable, "The Kobo edition changed; send the book again" unless copy && copy.sha256 == sha256

      file = pinned(copy)
      file = with_lock { usable(pinned(copy.reload)) || rebuild(copy, source) } if RemoteResult.failed?(file)
      touch(copy)
      file
    rescue Failure => error
      raise Busy, "The Kobo edition is being prepared; try again shortly" if error.code == "busy"

      raise KoboPublication::Unavailable, "The Kobo edition is unavailable; send the book again"
    rescue ActiveRecord::RecordNotFound, SystemCallError, FileCopyService::UnsafePathError
      raise KoboPublication::Unavailable, "The Kobo edition is unavailable; send the book again"
    end

    private

    def root
      self.class.root
    end

    def build(source, digest)
      limit = make_room([ MAX_COPY_BYTES, (source.stat.size * 2) + 16.megabytes ].min)
      written = write(source, limit)
      promote(written, source, digest)
    rescue KepubConverter::LimitExceeded
      raise limit < MAX_COPY_BYTES ? Failure.new("cache_full") : KepubConverter::Unsupported.new("too_large")
    end

    # Rebuilds a copy whose file was lost, from its unchanged source.
    def rebuild(copy, source)
      raise KoboPublication::Unavailable, "The Kobo edition is unavailable; send the book again" unless self.class.sha256(source) == copy.source_sha256

      written = write(source, copy.size_bytes + 1.megabyte)
      unless written[:sha256] == copy.sha256
        unlink_regular(written[:path])
        raise KoboPublication::Unavailable, "The Kobo edition can't be rebuilt identically; send the book again"
      end
      promote(written, source, copy.source_sha256)
      usable(pinned(copy.reload)) || raise(KoboPublication::Unavailable, "The Kobo edition is unavailable; send the book again")
    rescue KepubConverter::Unsupported, KepubConverter::LimitExceeded
      raise KoboPublication::Unavailable, "The Kobo edition can't be rebuilt; send the book again"
    end

    # Writes and verifies a complete copy in .incoming; returns its details.
    def write(source, limit)
      path = private_directory(root.join(INCOMING)).join("#{SecureRandom.hex(16)}.part")
      flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      result = File.open(path, flags, 0o600, binmode: true) do |io|
        KepubConverter.new(source).write(io, limit: limit).tap do
          io.flush
          io.fsync
        end
      end
      File.open(path, File::RDONLY | File::NOFOLLOW, binmode: true) do |file|
        raise KepubConverter::LimitExceeded if file.stat.size > limit

        spans = KepubConverter.verify(source, file, chapters: result.chapters)
        raise KepubConverter::Unsupported, "verification_failed" unless spans == result.spans

        { path: path, sha256: self.class.sha256(file), size: file.stat.size, chapters: result.chapters.size, spans: spans }
      end
    rescue StandardError
      unlink_regular(path) if path
      raise
    end

    def promote(written, source, digest)
      key = KoboKepubCopy.storage_key_for(written[:sha256])
      final = private_directory(root.join(key).dirname).join(File.basename(key))
      if regular?(final) && File.size(final) == written[:size] && self.class.sha256_path(final) == written[:sha256]
        unlink_regular(written[:path])
      else
        File.rename(written[:path], final)
        fsync_directory(final.dirname)
      end
      stat = File.lstat(final)
      copy = KoboKepubCopy.find_or_initialize_by(storage_key: key)
      copy.update!(converter: KepubConverter::VERSION, source_sha256: digest, source_size: source.stat.size,
        sha256: written[:sha256], size_bytes: written[:size], chapters: written[:chapters], spans: written[:spans],
        file_device: stat.dev.to_s, file_inode: stat.ino.to_s, file_changed_at: self.class.changed_at(stat), last_used_at: Time.current)
      copy
    ensure
      unlink_regular(written[:path]) if written
    end

    # The promoted file, or RemoteResult::Failed when it is gone, replaced or
    # changed since promotion.
    def pinned(copy)
      unless copy.storage_key.to_s.match?(KoboKepubCopy::STORAGE_KEY) && copy.file_device && copy.file_inode
        return RemoteResult::Failed.new(:unrecorded)
      end

      file = FileCopyService.open_pinned_regular_file(root.join(copy.storage_key).to_s, root: root.to_s,
        expected_device: Integer(copy.file_device), expected_inode: Integer(copy.file_inode))
      # Any write to the file after promotion changes its change time.
      return file if file.stat.size == copy.size_bytes && self.class.changed_at(file.stat) == copy.file_changed_at

      file.close
      RemoteResult::Failed.new(:changed)
    rescue FileCopyService::UnsafePathError, SystemCallError, ArgumentError, TypeError => error
      RemoteResult::Failed.new(error)
    end

    def usable(file)
      file unless RemoteResult.failed?(file)
    end

    def present?(copy)
      file = usable(pinned(copy))
      file.present?
    ensure
      file&.close
    end

    def touch(copy)
      copy.update_columns(last_used_at: Time.current) if copy.last_used_at.nil? || copy.last_used_at < 1.minute.ago
      copy
    end

    # Frees space by removing copies no delivery references and nobody used
    # recently, oldest first. Returns the bytes this copy may use.
    def make_room(needed)
      maximum = self.class.max_total_bytes
      KoboKepubCopy.unreferenced.where(last_used_at: ...RECENT.ago).or(KoboKepubCopy.unreferenced.where(last_used_at: nil))
        .order(Arel.sql("COALESCE(last_used_at, created_at) ASC"), :id).each do |candidate|
        break if used_bytes + needed <= maximum

        remove(candidate)
      end
      available = maximum - used_bytes
      raise Failure, "cache_full" unless available.positive?

      [ available, MAX_COPY_BYTES ].min
    end

    def used_bytes
      KoboKepubCopy.sum(:size_bytes)
    end

    def remove(copy)
      path = root.join(copy.storage_key)
      copy.destroy!
      unlink_regular(path) if copy.storage_key.to_s.match?(KoboKepubCopy::STORAGE_KEY)
    end

    # Under the lock: partial output of dead workers, files no row names (a
    # worker that died after its rename), and unreferenced rows whose file is gone.
    def reclaim
      incoming = private_directory(root.join(INCOMING))
      Dir.each_child(incoming) { |name| unlink_regular(incoming.join(name)) if name.match?(PART_NAME) }
      known = KoboKepubCopy.pluck(:storage_key).to_set
      Dir.each_child(root) do |prefix|
        next unless prefix.match?(/\A[0-9a-f]{2}\z/) && directory?(root.join(prefix))

        Dir.each_child(root.join(prefix)) do |name|
          unlink_regular(root.join(prefix, name)) if name.match?(COPY_NAME) && !known.include?("#{prefix}/#{name}")
        end
      end
      KoboKepubCopy.unreferenced.find_each { |copy| copy.destroy! unless present?(copy) }
    end

    def with_lock
      private_directory(root)
      File.open(root.join(".lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise Failure, "storage_unavailable" unless lock.stat.file?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + self.class.lock_wait
        until lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Failure, "busy" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
        yield
      end
    end

    def private_directory(path)
      relative = path.relative_path_from(root)
      raise Failure, "storage_unavailable" if relative.to_s.start_with?("..")

      FileUtils.mkdir_p(root, mode: 0o700)
      current = root
      [ root, *relative.each_filename.map { |part| current = current.join(part) } ].each do |directory|
        Dir.mkdir(directory, 0o700) unless File.exist?(directory)
        raise Failure, "storage_unavailable" unless directory?(directory)
      end
      path
    end

    def fsync_directory(path)
      File.open(path, File::RDONLY) { |directory| directory.fsync }
    rescue SystemCallError => error
      Rails.logger.info("[Kobo] Could not sync the Kobo edition directory (#{error.class.name})")
    end

    def directory?(path)
      File.directory?(path) && !File.symlink?(path)
    end

    def regular?(path)
      File.file?(path) && !File.symlink?(path)
    end

    def unlink_regular(path)
      File.unlink(path) if regular?(path)
    rescue SystemCallError => error
      Rails.logger.info("[Kobo] A Kobo edition file was already gone (#{error.class.name})")
    end
  end
end
