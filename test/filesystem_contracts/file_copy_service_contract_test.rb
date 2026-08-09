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
        root: @library_root.to_s,
        allow_compatibility_fallback: true
      )

      assert_equal content, destination.binread
      assert_equal content, source.binread
      assert_includes FileCopyService::LIBRARY_FILE_MODES,
        destination.stat.mode & 0o7777
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
        root: @library_root.to_s,
        allow_compatibility_fallback: true
      )
    end

    assert_equal "existing bytes", destination.binread
    assert_equal "new bytes", source.binread
    assert_no_publication_artifacts
  end

  test "concurrent publications retain exactly one complete winner" do
    destination = @library_root.join("winner.txt")
    sources = [ "first complete bytes", "second complete bytes" ].map.with_index do |content, index|
      @source_root.join("source-#{index}.txt").tap { |path| path.binwrite(content) }
    end
    ready = Queue.new
    release = Queue.new

    workers = sources.map do |source|
      Thread.new do
        ready << true
        release.pop
        FileCopyService.cp_noreplace(
          source.to_s,
          destination.to_s,
          root: @library_root.to_s,
          allow_compatibility_fallback: true
        )
        :published
      rescue Errno::EEXIST
        :occupied
      end
    end
    sources.size.times { ready.pop }
    sources.size.times { release << true }
    outcomes = workers.map(&:value)

    assert_equal [ :occupied, :published ], outcomes.sort
    assert_includes sources.map(&:binread), destination.binread
    assert_no_publication_artifacts
  ensure
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
        hardlink_mode: true,
        allow_compatibility_fallback: true
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
    source_snapshot = FileCopyService.snapshot_source_file(source.to_s)

    FileCopyService.cp_noreplace(
      source.to_s,
      destination.to_s,
      root: @library_root.to_s,
      source_snapshot: source_snapshot,
      allow_compatibility_fallback: true,
      require_durable: true
    )
    destination_snapshot = FileCopyService.verified_library_file_snapshot(
      source.to_s,
      destination.to_s,
      root: @library_root.to_s,
      source_snapshot: source_snapshot,
      require_durable: true
    )
    assert destination_snapshot

    removed = FileCopyService.remove_source_file(
      source_snapshot,
      destination_snapshot: destination_snapshot
    )
    if removed
      assert_not source.exist?
    else
      assert_equal content, source.binread
    end

    assert_equal content, destination.binread
    assert_no_publication_artifacts
    assert_empty Dir.children(@source_root).grep(/\A\.shelfarr-/)
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

  private

  def assert_no_publication_artifacts
    artifacts = Dir.children(@library_root).grep(/\A\.shelfarr-/)
    assert_empty artifacts
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
