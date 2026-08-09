# frozen_string_literal: true

require "test_helper"
require "set"
require "tmpdir"

class FileCopyServiceContractTest < ActiveSupport::TestCase
  setup do
    parent = Pathname(
      ENV.fetch("SHELFARR_FILESYSTEM_CONTRACT_ROOT", Dir.tmpdir)
    ).expand_path
    raise "Filesystem contract root must be an existing directory" unless parent.directory?

    @contract_root = Pathname(Dir.mktmpdir("shelfarr-filesystem-contract-", parent.to_s))
    @source_root = @contract_root.join("downloads")
    @library_root = @contract_root.join("library")
    FileUtils.mkdir_p([ @source_root, @library_root ])

    report_contract_profile_once
  end

  teardown do
    FileUtils.rm_rf(@contract_root) if @contract_root
  end

  test "creates writable nested library directories" do
    destination = @library_root.join("Author", "Book")

    FileCopyService.ensure_directory(
      destination.to_s,
      root: @library_root.to_s
    )

    assert destination.directory?
    assert File.writable?(destination)
    assert File.executable?(destination)
    assert_equal 0o775, destination.stat.mode & 0o777 if cifs_profile?

    probe = destination.join("write-probe")
    probe.binwrite("writable")
    assert_equal "writable", probe.binread
    probe.delete
    assert_not probe.exist?
  end

  test "publishes consecutive complete copies" do
    files = {
      "AIW.jpg" => "\xFF\xD8\xFF".b + SecureRandom.random_bytes(16_381),
      "AIW.txt" => SecureRandom.random_bytes(80_864)
    }

    files.each do |basename, content|
      source = @source_root.join(basename)
      destination = @library_root.join(basename)
      source.binwrite(content)

      FileCopyService.cp_noreplace(
        source.to_s,
        destination.to_s,
        root: @library_root.to_s
      )

      assert_equal content, destination.binread
      assert_equal content, source.binread
      if cifs_profile?
        assert_equal 0o775, destination.stat.mode & 0o777
      else
        assert_includes FileCopyService::LIBRARY_FILE_MODES,
          destination.stat.mode & 0o7777
      end
    end

    assert_no_publication_artifacts
  end

  test "never replaces an occupied destination" do
    source = @source_root.join("source.txt")
    destination = @library_root.join("occupied.txt")
    source.binwrite("new bytes")
    destination.binwrite("existing bytes")

    assert_raises(Errno::EEXIST) do
      FileCopyService.cp_noreplace(
        source.to_s,
        destination.to_s,
        root: @library_root.to_s
      )
    end

    assert_equal "existing bytes", destination.binread
    assert_equal "new bytes", source.binread
    assert_no_publication_artifacts
  end

  test "concurrent publications retain exactly one complete winner" do
    skip "noserverino cannot prove concurrent source or artifact identities" if cifs_noserverino_profile?

    destination = @library_root.join("winner.txt")
    sources = [ "first complete bytes", "second complete bytes" ].map.with_index do |content, index|
      @source_root.join("source-#{index}.txt").tap { |path| path.binwrite(content) }
    end
    ready = Queue.new
    release = Queue.new
    publishing = Queue.new
    publish = Queue.new
    workers = nil
    real_publish = FileCopyService.method(:publish_private_child_atomically_noreplace!)
    synchronized_publish = lambda do |*arguments, **options|
      publishing << true
      publish.pop
      real_publish.call(*arguments, **options)
    end

    outcomes = FileCopyService.stub(:publish_private_child_atomically_noreplace!, synchronized_publish) do
      workers = sources.map do |source|
        Thread.new do
          ready << true
          release.pop
          FileCopyService.cp_noreplace(
            source.to_s,
            destination.to_s,
            root: @library_root.to_s
          )
          :published
        rescue Errno::EEXIST
          :occupied
        end
      end
      sources.size.times { ready.pop }
      sources.size.times { release << true }
      sources.size.times { publishing.pop }
      sources.size.times { publish << true }
      workers.map(&:value)
    end

    assert_equal [ :occupied, :published ], outcomes.sort
    assert_includes sources.map(&:binread), destination.binread
    assert_no_publication_artifacts
  ensure
    workers&.size&.times do
      release << true
      publish << true
    end
    workers&.each { |worker| worker.join if worker.alive? }
  end

  test "hardlink import either succeeds or uses its typed copy fallback" do
    source = @source_root.join("chapter.mp3")
    destination = @library_root.join("chapter.mp3")
    source.binwrite(SecureRandom.random_bytes(32_768))

    hardlinked = begin
      FileCopyService.hardlink_noreplace(
        source.to_s,
        destination.to_s,
        root: @library_root.to_s,
        source_root: nil
      )
      true
    rescue FileCopyService::HardlinkUnsupportedError
      FileCopyService.cp_noreplace(
        source.to_s,
        destination.to_s,
        root: @library_root.to_s,
        hardlink_mode: true
      )
      false
    end

    assert_equal source.binread, destination.binread
    assert source.file?
    profile = ENV["SHELFARR_FILESYSTEM_CONTRACT_PROFILE"]
    assert hardlinked if profile == "cifs-serverino"
    assert_not hardlinked if profile == "cifs-noserverino"

    if hardlinked
      source.open("ab") do |file|
        file.write("shared mutation")
        file.flush
        begin
          file.fsync
        rescue Errno::EINVAL, Errno::EOPNOTSUPP
          nil
        end
      end
      assert_equal source.binread, destination.binread
    else
      copied_content = destination.binread
      source.open("ab") { |file| file.write("independent mutation") }
      assert_equal copied_content, destination.binread
    end
    assert_no_publication_artifacts
  end

  test "destructive import removes only a source it can still prove" do
    source = @source_root.join("move.epub")
    destination = @library_root.join("move.epub")
    content = SecureRandom.random_bytes(24_576)
    source.binwrite(content)

    if cifs_profile?
      error = assert_raises(Errno::ESTALE) do
        FileCopyService.mv_noreplace(
          source.to_s,
          destination.to_s,
          root: @library_root.to_s
        )
      end
      assert_match(/source changed after no-clobber move/, error.message)
      assert_equal content, source.binread
    else
      FileCopyService.mv_noreplace(
        source.to_s,
        destination.to_s,
        root: @library_root.to_s
      )
      assert_not source.exist?
    end

    assert_equal content, destination.binread
    assert_no_publication_artifacts
    assert_empty Dir.children(@source_root).grep(/\A\.shelfarr-/)
  end

  test "moves a local source into the mounted library and removes the source" do
    local_root = Pathname(Dir.mktmpdir("shelfarr-local-source-"))
    source = local_root.join("local.epub")
    destination = @library_root.join("local.epub")
    content = SecureRandom.random_bytes(24_576)
    source.binwrite(content)

    FileCopyService.mv_noreplace(
      source.to_s,
      destination.to_s,
      root: @library_root.to_s
    )

    assert_not source.exist?
    assert_equal content, destination.binread
    assert_no_publication_artifacts
  ensure
    FileUtils.rm_rf(local_root) if local_root
  end

  test "recovers interrupted publication artifacts in a nested library directory" do
    nested = @library_root.join("Author", "Book")
    FileUtils.mkdir_p(nested)
    token = SecureRandom.hex(16)
    temporary = nested.join(".shelfarr-copy-#{token}.tmp")
    lock = nested.join(".shelfarr-copy-#{token}.lock")
    temporary.binwrite("partial publication")
    temporary_stat = temporary.stat
    lock.binwrite(
      "#{FileCopyService::COPY_LOCK_MAGIC}:#{token}:full:" \
        "#{temporary_stat.dev}:#{temporary_stat.ino}"
    )

    if cifs_noserverino_profile?
      error = assert_raises(FileCopyService::AtomicPublicationUnsupportedError) do
        FileCopyService.cleanup_interrupted_copies(nested.to_s, root: @library_root.to_s)
      end
      assert_match(/manual cleanup/, error.message)
      assert temporary.exist?
      assert lock.exist?
      assert_equal "partial publication", temporary.binread
      retry_source = @source_root.join("retry.txt")
      retry_source.binwrite("retry bytes")
      entries = Dir.children(nested)
      assert_raises(FileCopyService::AtomicPublicationUnsupportedError) do
        FileCopyService.cp_noreplace(
          retry_source.to_s,
          nested.join("retry.txt").to_s,
          root: @library_root.to_s
        )
      end
      assert_equal entries.sort, Dir.children(nested).sort
    elsif cifs_profile?
      FileCopyService.cleanup_interrupted_copies(nested.to_s, root: @library_root.to_s)
      assert_not temporary.exist?
      assert_not lock.exist?
      quarantines = Dir.glob(nested.join(".shelfarr-copy-quarantine-*").to_s)
      assert_equal 1, quarantines.size
      assert_empty Dir.children(quarantines.sole)
      stale_time = Time.now - FileCopyService::COPY_QUARANTINE_STALE_AGE - 60
      File.utime(stale_time, stale_time, quarantines.sole)
      FileCopyService.cleanup_interrupted_copies(nested.to_s, root: @library_root.to_s)
      assert_no_publication_artifacts
    else
      FileCopyService.cleanup_interrupted_copies(nested.to_s, root: @library_root.to_s)
      assert_not temporary.exist?
      assert_not lock.exist?
      assert_no_publication_artifacts
    end
  end

  test "private file locks exclude a second process" do
    skip "fork is required for the cross-process lock contract" unless Process.respond_to?(:fork)

    lock = @library_root.join("contract.lock")
    enter_reader, enter_writer = IO.pipe
    result_reader, result_writer = IO.pipe
    child = fork do
      enter_writer.close
      result_reader.close
      enter_reader.read(1)
      acquired = FileCopyService.with_private_lock(
        lock.to_s,
        root: @library_root.to_s,
        nonblock: true
      ) { true }
      result_writer.write(acquired ? "acquired" : "blocked")
      result_writer.close
      exit! 0
    end
    enter_reader.close
    result_writer.close

    result = FileCopyService.with_private_lock(
      lock.to_s,
      root: @library_root.to_s
    ) do
      enter_writer.write("1")
      enter_writer.close
      result_reader.read
    end

    child_status = Process.wait2(child).last
    child = nil
    assert_equal "blocked", result
    assert_predicate child_status, :success?
  ensure
    enter_reader&.close unless enter_reader&.closed?
    enter_writer&.close unless enter_writer&.closed?
    result_reader&.close unless result_reader&.closed?
    result_writer&.close unless result_writer&.closed?
    if child
      begin
        Process.wait(child)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  test "service-specific interrupted attempts are reclaimed or block retries" do
    staging = @library_root.join("private-attempts")
    FileUtils.mkdir_p(staging)
    owner_token = UploadImportFileService.send(:filesystem_owner_token)
    upload_id = 42
    upload_attempt = staging.join("upload_#{upload_id}-#{owner_token}-#{"a" * 32}.tmp")
    libation_basename = "libation_42.m4b"
    libation_attempt = staging.join(
      ".#{libation_basename}.#{owner_token}.#{"b" * 32}.tmp"
    )
    upload_attempt.binwrite("upload attempt")
    libation_attempt.binwrite("libation attempt")
    upload = Struct.new(:id).new(upload_id)
    upload_service = UploadImportFileService.allocate
    upload_service.instance_variable_set(:@upload, upload)
    libation_pattern = /\A\.#{Regexp.escape(libation_basename)}\.#{Regexp.escape(owner_token)}\.[0-9a-f]{32}\.tmp\z/

    staging.open(File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |directory|
      if cifs_noserverino_profile?
        upload_error = assert_raises(UploadImportFileService::Error) do
          upload_service.send(:reclaim_interrupted_private_attempts!, directory)
        end
        libation_error = assert_raises(OwnedMediaImportFileService::Error) do
          OwnedMediaImportFileService.send(
            :reclaim_interrupted_copy_attempts!,
            directory,
            libation_pattern
          )
        end
        assert_match(/manual cleanup/, upload_error.message)
        assert_match(/manual cleanup/, libation_error.message)
        assert upload_attempt.exist?
        assert libation_attempt.exist?
      else
        upload_service.send(:reclaim_interrupted_private_attempts!, directory)
        OwnedMediaImportFileService.send(
          :reclaim_interrupted_copy_attempts!,
          directory,
          libation_pattern
        )
        sleep 2 if cifs_profile? # Let the configured one-second attribute cache expire.
        assert_not upload_attempt.exist?
        assert_not libation_attempt.exist?
      end
    end
  end

  private

  def assert_no_publication_artifacts
    artifacts = Dir.glob(
      File.join(@library_root, "**", ".shelfarr-*"),
      File::FNM_DOTMATCH
    )
    assert_empty artifacts
  end

  def cifs_profile?
    ENV.fetch("SHELFARR_FILESYSTEM_CONTRACT_PROFILE", "").start_with?("cifs-")
  end

  def cifs_noserverino_profile?
    ENV["SHELFARR_FILESYSTEM_CONTRACT_PROFILE"] == "cifs-noserverino"
  end

  def report_contract_profile_once
    profile = ENV["SHELFARR_FILESYSTEM_CONTRACT_PROFILE"]
    return if profile.blank?

    self.class.instance_variable_get(:@reported_profiles) ||
      self.class.instance_variable_set(:@reported_profiles, Set.new)
    reported = self.class.instance_variable_get(:@reported_profiles)
    return if reported.include?(profile)

    reported << profile
    warn "[filesystem-contract] profile=#{profile} root=#{@contract_root.parent} " \
      "options=#{ENV.fetch('SHELFARR_FILESYSTEM_CONTRACT_OPTIONS', 'unknown')}"
  end
end
