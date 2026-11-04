# frozen_string_literal: true

require "test_helper"

# Cancellation deletes only what an import can prove it published. These run
# the real import against a real filesystem so each proof comes from the
# publication that produced it.
class LibraryReplacementOwnershipTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("shelfarr-ownership")
    @library = File.join(@root, "library")
    @source = File.join(@root, "downloads", "release")
    FileUtils.mkdir_p(@library)
    FileUtils.mkdir_p(@source)
    File.binwrite(File.join(@source, "01.mp3"), "track one")
    File.binwrite(File.join(@source, "02.mp3"), "track two")
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobook_output_path, @library)
    SettingsService.set(:audiobook_path_template, "{author}/{title}")
    SettingsService.set(:download_local_path, File.dirname(@source))
    SettingsService.set(:completed_download_import_mode, "copy")
    @book = Book.create!(title: "Title", author: "Ada", book_type: :audiobook)
    @request = Request.create!(book: @book, user: users(:one), status: :downloading)
    @download = @request.downloads.create!(name: @book.title, status: :completed, download_path: @source, progress: 100)
    @folder = File.join(@library, "Ada", "Title")
    @track = File.join(@folder, "01.mp3")
    @second_track = File.join(@folder, "02.mp3")
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "a file a later writer put at a failed copy's destination survives cancellation" do
    import_failing_at_second_track(:cp_noreplace, publish_first: false)
    assert_includes @download.reload.library_replacement_state.to_s, @track
    assert_empty proofs
    FileUtils.mkdir_p(@folder)
    File.binwrite(@track, "unrelated bytes")

    @request.remove_as_admin!

    assert_equal "unrelated bytes", File.binread(@track)
  end

  test "a proof committed before a rename that never happened claims nothing" do
    real_rename = FileCopyService.method(:native_rename_noreplace)
    FileCopyService.stub(:native_rename_noreplace, lambda { |source_fd, source_name, destination_fd, destination_name|
      raise Errno::EIO if destination_name == "01.mp3"

      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    }) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert @request.reload.attention_needed?
    assert_not File.exist?(@track)
    assert_equal [ @track ], proofs.map { |proof| proof["path"] }
    File.binwrite(@track, "track one")

    @request.remove_as_admin!

    assert_equal "track one", File.binread(@track), "matching bytes alone are not proof of publication"
  end

  test "cancellation removes a copied file the import published before it failed" do
    import_failing_at_second_track(:cp_noreplace)

    assert_equal "track one", File.binread(@track)
    assert_equal [ @track ], proofs.map { |proof| proof["path"] }

    @request.remove_as_admin!

    assert_not File.exist?(@folder)
    assert_equal "track one", File.binread(File.join(@source, "01.mp3"))
  end

  test "a successful retry attaches files an earlier attempt published" do
    import_failing_at_second_track(:cp_noreplace)
    @request.clear_attention!

    NotificationService.stub(:request_completed, ->(_request) { true }) do
      PostProcessingJob.new(@download.id, 0, @download.reload.post_processing_job_id).perform_now
    end

    assert @request.reload.completed?, @request.issue_description
    assert_equal @folder, @book.reload.file_path
    assert_equal "track one", File.binread(@track)
    assert_equal "track two", File.binread(@second_track)
    assert_nil @download.reload.library_replacement_state
  end

  test "a foreign file swapped over a journaled entry survives even with identical bytes" do
    import_failing_at_second_track(:cp_noreplace)
    published = File.stat(@track)
    foreign = File.join(@folder, "incoming")
    File.binwrite(foreign, "track one")
    File.utime(published.atime, published.mtime, foreign)
    File.rename(foreign, @track)
    assert_equal published.mtime.to_r, File.stat(@track).mtime.to_r

    @request.remove_as_admin!

    assert_equal "track one", File.binread(@track)
  end

  test "a published inode rewritten in place is no longer the published file" do
    import_failing_at_second_track(:cp_noreplace)
    File.binwrite(@track, "someone else's edit")

    @request.remove_as_admin!

    assert_equal "someone else's edit", File.binread(@track)
  end

  test "a reused inode cannot pass for the published file" do
    File.binwrite(File.join(@library, "foreign.mp3"), "foreign bytes")
    foreign = File.join(@library, "foreign.mp3")
    proof = publication_proof(foreign)

    { "size" => proof["size"] + 1, "digest" => "0" * 64, "mtime_ns" => proof["mtime_ns"] + 1 }.each do |field, value|
      journal_proofs(foreign, proof.merge(field => value))

      assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)

      assert_equal "foreign bytes", File.binread(foreign), "#{field} did not reject the inode"
    end
  end

  test "a parent directory that was replaced proves nothing" do
    import_failing_at_second_track(:cp_noreplace)
    File.rename(@folder, "#{@folder}-moved")
    FileUtils.mkdir_p(@folder)
    File.rename(File.join("#{@folder}-moved", "01.mp3"), @track)

    @request.remove_as_admin!

    assert_equal "track one", File.binread(@track)
  end

  test "an ancestor replaced by a symlink is never followed" do
    import_failing_at_second_track(:cp_noreplace)
    moved = "#{@folder}-moved"
    File.rename(@folder, moved)
    File.symlink(moved, @folder)

    @request.remove_as_admin!

    assert_equal "track one", File.binread(File.join(moved, "01.mp3"))
  end

  test "an entry swapped in between the proof check and the claim is restored" do
    import_failing_at_second_track(:cp_noreplace)
    proof = proofs.sole
    service = deletion_service(@track)
    real_rename = service.method(:native_rename_noreplace)
    swapped = false

    outcome = service.stub(:native_rename_noreplace, lambda { |source_fd, source_name, destination_fd, destination_name|
      unless swapped
        swapped = true
        foreign = File.join(@folder, "incoming")
        File.binwrite(foreign, "swapped in")
        File.rename(foreign, @track)
      end
      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    }) do
      service.delete_proven_publication!(proof)
    end

    assert_equal :retained, outcome
    assert_equal "swapped in", File.binread(@track)
    assert_equal [ "01.mp3" ], Dir.children(@folder)
  end

  test "a claimed foreign entry stays quarantined and blocks cancellation when its name was retaken" do
    import_failing_at_second_track(:cp_noreplace)
    proof = proofs.sole
    service = deletion_service(@track)
    real_rename = service.method(:native_rename_noreplace)
    calls = 0

    service.stub(:native_rename_noreplace, lambda { |source_fd, source_name, destination_fd, destination_name|
      calls += 1
      if calls == 1
        foreign = File.join(@folder, "incoming")
        File.binwrite(foreign, "swapped in")
        File.rename(foreign, @track)
      else
        File.binwrite(@track, "taken again")
      end
      real_rename.call(source_fd, source_name, destination_fd, destination_name)
    }) do
      assert_raises(SafeLibraryDeletionService::Error) { service.delete_proven_publication!(proof) }
    end

    assert_equal "taken again", File.binread(@track)
    quarantined = Dir.children(@folder).reject { |name| name == "01.mp3" }.sole
    assert_equal "swapped in", File.binread(File.join(@folder, quarantined))
  end

  test "cancellation finishes a removal a crash stopped after the name was claimed" do
    import_failing_at_second_track(:cp_noreplace)
    stat = File.stat(@track)
    File.rename(@track, File.join(@folder, ".shelfarr-delete-#{@book.id}-#{stat.dev}-#{stat.ino}"))

    @request.remove_as_admin!

    assert_not File.exist?(@folder)
  end

  test "a proven removal on NFS uses the checked rename only with the single-writer opt-in" do
    import_failing_at_second_track(:cp_noreplace)

    without_rename_noreplace(allow_nonatomic: false) do
      assert RemoteResult.failed?(LibraryReplacement.prepare_cancellation!(@download.reload))
    end
    assert_equal "track one", File.binread(@track)
    assert_equal [ @track ], proofs.map { |proof| proof["path"] }

    without_rename_noreplace(allow_nonatomic: true) do
      assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)
    end
    assert_not File.exist?(@track)
    assert_nil @download.reload.library_replacement_state
  end

  test "an unproven reference on NFS is retained even with the rename opt-in" do
    SettingsService.set(:completed_download_import_mode, "reference")
    import_failing_at_second_track(:reference_noreplace)

    without_rename_noreplace(allow_nonatomic: true) do
      assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)
    end

    assert File.symlink?(@track)
    assert_equal "track one", File.binread(File.join(@source, "01.mp3"))
  end

  test "a replacement plan with no proof keeps whatever now occupies its destination" do
    previous = File.join(@library, "Ada", "Previous")
    destination = File.join(@library, "Ada", "Planned")
    FileUtils.mkdir_p(previous)
    File.binwrite(File.join(previous, "old.mp3"), "old audio")
    FileUtils.mkdir_p(File.join(destination, "nested"))
    File.binwrite(File.join(destination, "nested", "foreign.mp3"), "foreign audio")
    @book.update!(file_path: previous)
    persist_plan!(previous, destination)

    assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)

    assert_equal "foreign audio", File.binread(File.join(destination, "nested", "foreign.mp3"))
    assert_equal "old audio", File.binread(File.join(previous, "old.mp3"))
    assert_nil @download.reload.library_replacement_state
  end

  test "a replacement plan with no proof keeps a file at its file destination" do
    previous = File.join(@library, "previous.m4b")
    destination = File.join(@library, "planned.m4b")
    File.binwrite(previous, "old audio")
    File.binwrite(destination, "foreign audio")
    @book.update!(file_path: previous)
    persist_plan!(previous, destination, layout: "file")

    assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)

    assert_equal "foreign audio", File.binread(destination)
  end

  test "a replacement plan removes the empty folder it created for itself" do
    previous = File.join(@library, "Ada", "Previous")
    destination = File.join(@library, "Ada", "Planned")
    FileUtils.mkdir_p(previous)
    FileUtils.mkdir_p(destination)
    File.binwrite(File.join(previous, "old.mp3"), "old audio")
    @book.update!(file_path: previous)
    persist_plan!(previous, destination)

    assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)

    assert_not File.exist?(destination)
    assert File.exist?(previous)
  end

  test "a path journaled without a proof is left in place" do
    FileUtils.mkdir_p(@folder)
    File.binwrite(@track, "from an earlier version")
    @download.update!(
      post_processing_job_id: "finished-import",
      library_replacement_state: JSON.generate("published_paths" => [ @track ])
    )

    assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)

    assert_equal "from an earlier version", File.binread(@track)
    assert_nil @download.reload.library_replacement_state
  end

  test "an unreadable proof blocks cancellation instead of guessing" do
    @download.update!(
      library_replacement_state: JSON.generate(
        "published_paths" => [ @track ],
        "publication_proofs" => [ { "path" => @track, "kind" => "file" } ]
      )
    )

    assert RemoteResult.failed?(LibraryReplacement.prepare_cancellation!(@download.reload))
    assert @download.reload.library_replacement_state.present?
  end

  test "pruning keeps a directory that holds anything" do
    FileUtils.mkdir_p(@folder)
    File.binwrite(@track, "foreign")

    assert_equal :retained, deletion_service(@folder).remove_empty_directory!
    assert_equal "foreign", File.binread(@track)

    File.delete(@track)
    assert_equal :removed, deletion_service(@folder).remove_empty_directory!
    assert_equal :absent, deletion_service(@folder).remove_empty_directory!
  end

  test "losing the destination race forgets only this attempt's proof" do
    journal_proofs(@track, "kind" => "file", "device" => 1, "inode" => 2, "size" => 3, "mtime_ns" => 4, "parent_device" => 1, "parent_inode" => 5)
    earlier = proofs.sole
    attempt = earlier.except("path").merge("inode" => 9)
    LibraryReplacement.record_publication_proofs!(@download, @track => attempt)

    assert_equal true, LibraryReplacement.forget_published_path!(@download, @track, proof: attempt)
    assert_equal [ earlier ], proofs
    assert_includes LibraryReplacement.load(@download.reload).published_paths, @track

    assert_equal true, LibraryReplacement.forget_published_path!(@download, @track, proof: earlier.except("path"))
    assert_empty proofs
    assert_empty LibraryReplacement.load(@download.reload).published_paths
  end

  test "hardlink cancellation retains the ambiguous name and its source" do
    SettingsService.set(:completed_download_import_mode, "hardlink")
    import_failing_at_second_track(:hardlink_noreplace)

    source = File.join(@source, "01.mp3")
    assert_equal File.stat(source).ino, File.stat(@track).ino
    assert_equal File.stat(source).ino, proofs.sole["inode"]

    @request.remove_as_admin!

    assert File.exist?(@track)
    assert_equal "track one", File.binread(source)
  end

  test "hardlink cancellation keeps a foreign file swapped over the journaled name" do
    SettingsService.set(:completed_download_import_mode, "hardlink")
    import_failing_at_second_track(:hardlink_noreplace)
    File.delete(@track)
    File.binwrite(@track, "track one")

    @request.remove_as_admin!

    assert_equal "track one", File.binread(@track)
  end

  test "a retained-source fallback copy is proven when hardlinks are unavailable" do
    SettingsService.set(:completed_download_import_mode, "hardlink")
    real_copy = FileCopyService.method(:cp_noreplace)

    FileCopyService.stub(:hardlink_noreplace, ->(*) { raise FileCopyService::HardlinkUnsupportedError }) do
      FileCopyService.stub(:cp_noreplace, lambda { |source, destination, **options|
        raise Errno::EIO if File.basename(source) == "02.mp3"

        real_copy.call(source, destination, **options)
      }) do
        PostProcessingJob.perform_now(@download.id)
      end
    end

    assert_not_equal File.stat(File.join(@source, "01.mp3")).ino, File.stat(@track).ino
    assert_equal File.stat(@track).ino, proofs.sole["inode"]

    @request.remove_as_admin!

    assert_not File.exist?(@track)
    assert_equal "track one", File.binread(File.join(@source, "01.mp3"))
  end

  test "move mode keeps the source until cancellation has removed the proven copy" do
    SettingsService.set(:completed_download_import_mode, "move")
    import_failing_at_second_track(:cp_noreplace)

    assert_equal "track one", File.binread(@track)
    assert_equal "track one", File.binread(File.join(@source, "01.mp3"))

    @request.remove_as_admin!

    assert_not File.exist?(@track)
    assert_equal "track one", File.binread(File.join(@source, "01.mp3"))
  end

  test "move mode keeps a later writer's file after a failed publication" do
    SettingsService.set(:completed_download_import_mode, "move")
    import_failing_at_second_track(:cp_noreplace, publish_first: false)
    FileUtils.mkdir_p(@folder)
    File.binwrite(@track, "unrelated bytes")

    @request.remove_as_admin!

    assert_equal "unrelated bytes", File.binread(@track)
  end

  test "reference cancellation retains the unproven link and its target" do
    SettingsService.set(:completed_download_import_mode, "reference")
    import_failing_at_second_track(:reference_noreplace)

    assert File.symlink?(@track)
    assert_equal "symlink", proofs.sole["kind"]

    @request.remove_as_admin!

    assert File.symlink?(@track)
    assert_equal "track one", File.binread(File.join(@source, "01.mp3"))
  end

  test "reference cancellation keeps a symlink that points somewhere else" do
    SettingsService.set(:completed_download_import_mode, "reference")
    import_failing_at_second_track(:reference_noreplace)
    File.delete(@track)
    File.symlink(File.join(@source, "02.mp3"), @track)

    @request.remove_as_admin!

    assert_equal File.join(@source, "02.mp3"), File.readlink(@track)
  end

  test "reference cancellation keeps a regular file at the journaled name" do
    SettingsService.set(:completed_download_import_mode, "reference")
    import_failing_at_second_track(:reference_noreplace)
    File.delete(@track)
    File.binwrite(@track, "track one")

    @request.remove_as_admin!

    assert_equal "track one", File.binread(@track)
  end

  test "a reference proof committed before symlinkat claims nothing it did not create" do
    SettingsService.set(:completed_download_import_mode, "reference")
    FileCopyService.stub(:native_symlinkat, ->(*) { raise Errno::EIO }) do
      PostProcessingJob.perform_now(@download.id)
    end
    assert_not File.symlink?(@track)
    assert_equal [ @track ], proofs.map { |proof| proof["path"] }
    FileUtils.mkdir_p(@folder)
    File.binwrite(@track, "unrelated bytes")

    @request.remove_as_admin!

    assert_equal "unrelated bytes", File.binread(@track)
  end

  test "a legacy reference quarantine blocks cancellation for manual recovery" do
    SettingsService.set(:completed_download_import_mode, "reference")
    import_failing_at_second_track(:reference_noreplace)
    File.rename(@track, File.join(@folder, ".shelfarr-delete-#{@book.id}-ref-0123456789abcdef"))

    assert_raises(Request::CancellationBlockedError) { @request.remove_as_admin! }

    assert File.symlink?(File.join(@folder, ".shelfarr-delete-#{@book.id}-ref-0123456789abcdef"))
    assert @download.reload.library_replacement_state.present?
    assert_equal "track one", File.binread(File.join(@source, "01.mp3"))
  end

  test "a failed reference publication does not own a later identical target link" do
    SettingsService.set(:completed_download_import_mode, "reference")
    FileCopyService.stub(:native_symlinkat, ->(*) { raise Errno::EIO }) do
      PostProcessingJob.perform_now(@download.id)
    end
    assert @request.reload.attention_needed?
    assert_not File.symlink?(@track)
    target = File.join(@source, "01.mp3")
    File.symlink(target, @track)

    @request.remove_as_admin!

    assert File.symlink?(@track), "the failed import never created this link"
    assert_equal target, File.readlink(@track)
  end

  test "a failed hardlink publication does not own a later last link to the same inode" do
    SettingsService.set(:completed_download_import_mode, "hardlink")
    FileCopyService.stub(:publish_private_child_atomically_noreplace!, ->(*) { raise Errno::EIO }) do
      PostProcessingJob.perform_now(@download.id)
    end
    assert @request.reload.attention_needed?
    assert_not File.exist?(@track)
    source = File.join(@source, "01.mp3")
    File.link(source, @track)
    File.unlink(source)

    @request.remove_as_admin!

    assert File.exist?(@track), "the foreign name was the inode's last link"
    assert_equal "track one", File.binread(@track)
  end

  test "a writer editing an already hashed chunk prevents proven deletion" do
    File.binwrite(File.join(@source, "01.mp3"), "a" * (FileCopyService::BUFFER_SIZE * 2))
    import_failing_at_second_track(:cp_noreplace)
    real_hash = FileCopyService.method(:io_content_identity)
    modified = false
    File.open(@track, "r+b") do |writer|
      FileCopyService.stub(:io_content_identity, lambda { |io, **options|
        original_read = io.method(:read)
        io.define_singleton_method(:read) do |*args|
          result = original_read.call(*args)
          if result && !modified
            writer.rewind
            writer.write("B")
            writer.flush
            modified = true
          end
          result
        end
        real_hash.call(io, **options)
      }) do
        @request.remove_as_admin!
      end
    end

    assert modified
    assert File.exist?(@track), "the digest read missed the writer's edit"
    assert_equal "B", File.binread(@track, 1)
  end

  test "an interrupted claim read error preserves the journal when its original path is absent" do
    import_failing_at_second_track(:cp_noreplace)
    claimed = claim_track!
    journal = @download.reload.library_replacement_state

    FileCopyService.stub(:publication_content_matches?, ->(*) { raise Errno::EIO }) do
      assert RemoteResult.failed?(LibraryReplacement.prepare_cancellation!(@download.reload))
    end

    assert_equal journal, @download.reload.library_replacement_state
    assert_equal "track one", File.binread(claimed)
  end

  test "an absent stale proof does not hide a later interrupted claim" do
    import_failing_at_second_track(:cp_noreplace)
    actual = proofs.sole
    stale = actual.merge("inode" => actual.fetch("inode") + 1_000_000)
    @download.update!(library_replacement_state: JSON.generate(
      "published_paths" => [ @track ], "publication_proofs" => [ stale, actual ]
    ))
    claimed = claim_track!

    assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)

    assert_not File.exist?(claimed), "all recorded proofs must be tried"
    assert_nil @download.reload.library_replacement_state
  end

  test "a legacy file proof without exclusive inode provenance retains the file" do
    import_failing_at_second_track(:cp_noreplace)
    state = JSON.parse(@download.reload.library_replacement_state)
    state.fetch("publication_proofs").each { |proof| proof.delete("exclusive_inode") }
    @download.update!(library_replacement_state: JSON.generate(state))

    @request.remove_as_admin!

    assert_equal "track one", File.binread(@track)
  end

  test "a copy adopted through another hardlink is retained" do
    import_failing_at_second_track(:cp_noreplace)
    adopted = File.join(@library, "adopted.mp3")
    File.link(@track, adopted)

    @request.remove_as_admin!

    assert_equal "track one", File.binread(@track)
    assert_equal "track one", File.binread(adopted)
  end

  test "a busy absent-path claim keeps its recovery journal" do
    import_failing_at_second_track(:cp_noreplace)
    claimed = claim_track!
    journal = @download.reload.library_replacement_state
    lock = LibraryReplacement.share_reused_destination!(@track)
    begin
      assert_equal false, LibraryReplacement.prepare_cancellation!(@download.reload)
    ensure
      LibraryReplacement.release_destination_lock(lock)
    end

    assert_equal journal, @download.reload.library_replacement_state
    assert_equal "track one", File.binread(claimed)
  end

  test "the cleanup read budget restores a claim and preserves unverified bytes" do
    File.binwrite(File.join(@source, "01.mp3"), "a" * (FileCopyService::BUFFER_SIZE * 2))
    import_failing_at_second_track(:cp_noreplace)
    reads = 0
    real_hash = FileCopyService.method(:io_content_identity)
    FileCopyService.stub(:publication_verification_time, -> { reads.positive? ? 1.0 : 0.0 }) do
      FileCopyService.stub(:io_content_identity, lambda { |io, **options|
        original_read = io.method(:read)
        io.define_singleton_method(:read) do |*args|
          result = original_read.call(*args)
          reads += 1 if result
          result
        end
        real_hash.call(io, **options)
      }) do
        assert_equal true, LibraryReplacement.prepare_cancellation!(@download.reload)
      end
    end

    assert_equal 1, reads, "the deadline must be checked between chunks"
    assert_equal "a" * (FileCopyService::BUFFER_SIZE * 2), File.binread(@track)
    assert_equal [ "01.mp3" ], Dir.children(@folder)
    assert_nil @download.reload.library_replacement_state
  end

  private

  def claim_track!
    stat = File.stat(@track)
    claimed = File.join(@folder, ".shelfarr-delete-#{@book.id}-#{stat.dev}-#{stat.ino}")
    File.rename(@track, claimed)
    claimed
  end

  def import_failing_at_second_track(operation, publish_first: true)
    real_operation = FileCopyService.method(operation)
    FileCopyService.stub(operation, lambda { |source, destination, **options|
      raise Errno::EIO if File.basename(source) == "02.mp3" || !publish_first

      real_operation.call(source, destination, **options)
    }) do
      PostProcessingJob.perform_now(@download.id)
    end

    assert @request.reload.attention_needed?, "the import was expected to stop"
    assert_nil @book.reload.file_path
  end

  def without_rename_noreplace(allow_nonatomic:, &block)
    SettingsService.set(:allow_nonatomic_nfs_directory_publication, allow_nonatomic)
    FilesystemSyscalls.stub(:rename_noreplace, ->(*) { raise Errno::EINVAL, "renameat2" }, &block)
  end

  def proofs
    state = LibraryReplacement.load(@download.reload)
    state ? state.publication_proofs : []
  end

  def publication_proof(path)
    stat = File.lstat(path)
    parent = File.stat(File.dirname(path))
    {
      "kind" => "file",
      "exclusive_inode" => true,
      "device" => stat.dev,
      "inode" => stat.ino,
      "size" => stat.size,
      "mtime_ns" => (stat.mtime.to_r * 1_000_000_000).to_i,
      "digest" => Digest::SHA256.file(path).hexdigest,
      "parent_device" => parent.dev,
      "parent_inode" => parent.ino
    }
  end

  def journal_proofs(path, proof)
    @download.update!(library_replacement_state: nil, post_processing_job_id: "finished-import")
    LibraryReplacement.record_publication_proofs!(@download, path => proof)
  end

  def persist_plan!(previous, destination, layout: "directory")
    LibraryReplacement.persist!(
      @download,
      previous_path: previous,
      destination: destination,
      book_path: destination,
      layout: layout
    )
  end

  def deletion_service(path)
    record = Book.find(@book.id)
    record.file_path = path
    SafeLibraryDeletionService.new(record)
  end
end
