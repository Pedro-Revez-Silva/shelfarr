# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

module AndroidUpdates
  # The server's verified copy of Android builds, under storage/app_updates:
  #
  #   lock                         held by the one process refreshing
  #   staging/                     downloads in progress (discarded on the next refresh)
  #   apks/<channel>/<code>-<sha256>.apk   verified, read-only, never rewritten
  #   channels/<channel>.json      the promoted build, and the one before it
  #   status.json                  outcome of the last refresh, without URLs
  #
  # A build becomes visible only by renaming a fully verified file into apks/
  # and then renaming a new channel document into place, so a reader in any
  # process sees either the previous build or the new one. Promotions survive
  # restarts and are only replaced by a newer verified build.
  class Store
    Promotion = Data.define(:current, :previous, :promoted_at)
    EMPTY = Promotion.new(current: nil, previous: nil, promoted_at: nil)
    STATE_SCHEMA = 1
    MAX_STATE_BYTES = 256 * 1024
    NO_DOCUMENT = {}.freeze
    APK_NAME = /\A(?<code>[1-9]\d{0,9})-(?<sha>[0-9a-f]{64})\.apk\z/
    HASH_CHUNK = 1024 * 1024

    class << self
      attr_writer :root

      def root
        @root || Rails.root.join("storage", "app_updates")
      end
    end

    attr_reader :root

    def initialize(root = self.class.root)
      @root = Pathname.new(root)
    end

    def promotion(channel)
      document = read_json(channel_path(channel))
      return EMPTY unless document.is_a?(Hash) && document["schema_version"] == STATE_SCHEMA && document["channel"] == channel

      current = Release.from_h(document["current"])
      previous = document["previous"] && Release.from_h(document["previous"])
      return EMPTY unless current.channel == channel && (previous.nil? || previous.channel == channel)

      Promotion.new(current: current, previous: previous, promoted_at: document["promoted_at"])
    rescue InvalidRelease => e
      Rails.logger.warn "[AndroidUpdates] Ignoring an unreadable #{channel} cache entry: #{e.message}"
      EMPTY
    end

    # The promoted build, when it can be served to this server's apps.
    def ready_release(channel)
      current = promotion(channel).current
      current if current&.compatible? && present?(channel, current)
    end

    # Opens one of the channel's promoted files for reading. Only the current
    # and the previous build are served; the name is never used as a path.
    def open_apk(channel, file_name)
      promotion = promotion(channel)
      release = [ promotion.current, promotion.previous ].compact.find { |candidate| candidate.file_name == file_name }
      return unless release&.compatible?

      file = open_regular(apk_path(channel, release))
      return unless file.is_a?(File)

      if file.stat.size == release.size_bytes
        [ release, file ]
      else
        file.close
        nil
      end
    end

    def present?(channel, release)
      path = apk_path(channel, release)
      File.file?(path) && !File.symlink?(path) && File.size(path) == release.size_bytes
    end

    # Re-reads a cached build completely and compares it with its checksum.
    def intact?(channel, release)
      file = open_regular(apk_path(channel, release))
      return false unless file.is_a?(File)

      digest = Digest::SHA256.new
      size = 0
      buffer = +""
      while file.read(HASH_CHUNK, buffer)
        size += buffer.bytesize
        digest.update(buffer)
      end
      size == release.size_bytes && digest.hexdigest == release.sha256
    ensure
      file.close if file.is_a?(File)
    end

    # Runs the block while holding the cross-process refresh lock, or returns
    # :busy straight away when another process holds it.
    def with_refresh_lock
      ensure_directory(root)
      File.open(root.join("lock"), File::RDWR | File::CREAT, 0o644) do |lock|
        return :busy unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end

    # Only call while holding the refresh lock: any staged file is abandoned.
    def clear_staging!
      directory = ensure_directory(root.join("staging"))
      directory.each_child { |child| FileUtils.rm_f(child) if child.basename.to_s.end_with?(".part") }
    end

    # Yields a new staging file and returns its path. The file is removed if
    # the block raises.
    def stage
      path = ensure_directory(root.join("staging")).join("#{SecureRandom.hex(16)}.part")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW | File::BINARY, 0o600) do |file|
        file.binmode
        yield file
        file.flush
        file.fsync
      end
      path
    rescue StandardError
      FileUtils.rm_f(path) if path
      raise
    end

    def discard_staged(path)
      FileUtils.rm_f(path) if path
    end

    # Makes a verified staged file the channel's current build, keeping the
    # one it replaces so phones that already fetched the old feed still finish.
    def promote!(channel, release, staged_path, promoted_at: Time.current)
      directory = ensure_directory(root.join("apks", channel))
      File.chmod(0o444, staged_path)
      File.rename(staged_path, directory.join(release.file_name))
      sync_directory(directory)

      previous = promotion(channel).current
      previous = nil if previous&.same_build?(release)
      write_atomically(channel_path(channel), JSON.pretty_generate(
        "schema_version" => STATE_SCHEMA,
        "channel" => channel,
        "promoted_at" => promoted_at.utc.iso8601,
        "current" => release.to_h,
        "previous" => previous&.to_h
      ))
      prune(channel, [ release, previous ].compact)
    end

    # Removes a damaged cached file so it is no longer served.
    def discard_apk(channel, release)
      FileUtils.rm_f(apk_path(channel, release))
    end

    # Drops a channel's promotion and files (an operator choice, allowing a
    # lower version code to be cached next time).
    def forget!(channel)
      FileUtils.rm_f(channel_path(channel))
      FileUtils.rm_rf(root.join("apks", channel))
    end

    def status
      document = read_json(root.join("status.json"))
      document.is_a?(Hash) ? document : {}
    end

    def write_status(document)
      ensure_directory(root)
      write_atomically(root.join("status.json"), JSON.pretty_generate(document))
    end

    def apk_path(channel, release)
      raise ArgumentError, "unknown channel" unless Configuration::CHANNELS.include?(channel)

      root.join("apks", channel, release.file_name)
    end

    private

    def channel_path(channel)
      raise ArgumentError, "unknown channel" unless Configuration::CHANNELS.include?(channel)

      root.join("channels", "#{channel}.json")
    end

    # An open regular file, or :missing (absent, a symlink or not a file).
    def open_regular(path)
      file = File.open(path, File::RDONLY | File::NOFOLLOW | File::BINARY).binmode
      return file if file.stat.file?

      file.close
      :missing
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES
      :missing
    end

    def read_json(path)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        return NO_DOCUMENT unless file.stat.file? && file.stat.size <= MAX_STATE_BYTES

        JSON.parse(file.read, max_nesting: 8)
      end
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, JSON::ParserError, JSON::NestingError
      NO_DOCUMENT
    end

    def write_atomically(path, content)
      directory = ensure_directory(path.dirname)
      temporary = directory.join(".#{path.basename}.#{SecureRandom.hex(8)}.tmp")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o644) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
      sync_directory(directory)
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    def prune(channel, keep)
      names = keep.map(&:file_name)
      root.join("apks", channel).each_child do |child|
        next if names.include?(child.basename.to_s)

        FileUtils.rm_f(child) if child.basename.to_s.match?(APK_NAME) && !child.directory?
      end
    end

    def ensure_directory(path)
      FileUtils.mkdir_p(path, mode: 0o755)
      raise IOError, "#{path.basename} is not a directory" unless File.lstat(path).directory? || path == root

      path
    end

    def sync_directory(path)
      File.open(path, File::RDONLY) { |directory| directory.fsync }
    rescue Errno::EINVAL, Errno::EACCES
      # Some filesystems cannot fsync a directory; the rename is still atomic.
      :unsynced
    end
  end
end
