# frozen_string_literal: true

require "test_helper"

class UploadTest < ActiveSupport::TestCase
  test "manual matching creates the inferred format with only corrected metadata" do
    %w[m4b epub cbz].zip(%w[audiobook ebook comicbook]).each do |extension, book_type|
      upload = Upload.create!(user: users(:two), original_filename: "unrecognized.#{extension}", status: :failed)

      assert_difference "Book.count", 1 do
        upload.match_and_retry!(title: "  Corrected title  ", author: "  Corrected author  ")
      end

      assert upload.reload.pending?
      assert upload.manual_match?
      assert upload.manual_match_created_book?
      assert_equal book_type, upload.book_type
      assert_equal book_type, upload.book.book_type
      assert_equal "Corrected title", upload.book.title
      assert_equal "Corrected author", upload.book.author
      assert_equal extension == "cbz" ? "graphic" : "book", upload.book.content_kind
    end
  end

  test "stale duplicate manual match cannot create a second book or replace the choice" do
    upload = Upload.create!(user: users(:two), original_filename: "unrecognized.epub", status: :failed)
    stale_upload = Upload.find(upload.id)
    upload.match_and_retry!(title: "Chosen title")

    assert_no_difference "Book.count" do
      assert_raises(ActiveRecord::RecordInvalid) { stale_upload.match_and_retry!(title: "Second title") }
    end
    assert_equal "Chosen title", upload.reload.book.title
    assert upload.pending?
  end

  test "every durable recovery marker blocks manual reassignment" do
    upload = Upload.create!(user: users(:two), original_filename: "unrecognized.epub", status: :failed)
    %i[destination_path destination_root destination_configured_root library_path content_sha256 cleanup_source_path book_reservation_token].each do |attribute|
      upload.update!(attribute => "reserved-state")
      assert_not upload.manual_match_available?, attribute.to_s
      assert_no_difference "Book.count" do
        assert_raises(ActiveRecord::RecordInvalid) { upload.match_and_retry!(title: "Replacement") }
      end
      upload.update!(attribute => nil)
    end
    assert upload.manual_match_available?
  end

  test "invalid new-book metadata rolls back the match and can be corrected" do
    upload = Upload.create!(user: users(:two), original_filename: "unrecognized.epub", status: :failed, error_message: "Original failure")

    assert_no_difference "Book.count" do
      assert_raises(ActiveRecord::RecordInvalid) { upload.match_and_retry!(title: "  ") }
    end
    assert upload.reload.failed?
    assert_not upload.manual_match?
    assert_nil upload.book_id
    assert_equal "Original failure", upload.error_message

    upload.match_and_retry!(title: "Corrected title")
    assert upload.reload.pending?
  end

  test "replacing an owned manual creation prunes the abandoned matching candidate" do
    upload = create_manual_match
    abandoned = upload.book
    assert_equal abandoned, BookMatcherService.match(title: abandoned.title, author: abandoned.author, book_type: :ebook).book

    assert_no_difference "Book.count" do
      upload.match_and_retry!(title: "Replacement title")
    end

    assert_not Book.exists?(abandoned.id)
    assert_not_equal abandoned.id, BookMatcherService.match(title: abandoned.title, author: abandoned.author, book_type: :ebook).book&.id
    assert_equal "Replacement title", upload.reload.book.title
    assert upload.manual_match_created_book?
  end

  test "selecting the same owned book retains ownership for later abandonment" do
    upload = create_manual_match
    original = upload.book

    upload.match_and_retry!(book_id: original.id)
    assert upload.reload.manual_match_created_book?
    assert_equal original, upload.book

    upload.update!(status: :failed)
    upload.match_and_retry!(title: "A later correction")
    assert_not Book.exists?(original.id)
  end

  test "replacing or deleting an existing selection never prunes that book" do
    existing = Book.create!(title: "Existing metadata", book_type: :ebook)
    upload = create_manual_match
    created_id = upload.book_id

    upload.match_and_retry!(book_id: existing.id)
    assert_not upload.reload.manual_match_created_book?
    assert_not Book.exists?(created_id)
    upload.update!(status: :failed)
    upload.match_and_retry!(title: "New corrected metadata")
    assert Book.exists?(existing.id)
    upload.update!(status: :failed)
    upload.match_and_retry!(book_id: existing.id)
    upload.destroy!
    assert Book.exists?(existing.id)
  end

  test "deleting a pending or failed upload prunes only its unused manual creation" do
    [ :pending, :failed ].each do |status|
      upload = create_manual_match(status: status)
      book_id = upload.book_id

      assert_difference "Book.count", -1 do
        upload.destroy!
      end

      assert_not Upload.exists?(upload.id)
      assert_not Book.exists?(book_id)
    end
  end

  test "completed uploads preserve the created book even if its file is no longer available" do
    upload = create_manual_match(status: :completed)
    book_id = upload.book_id

    upload.destroy!

    assert Book.exists?(book_id)
  end

  test "processing or recovery-bearing uploads cannot prune their selected creation" do
    [ { status: :processing }, { destination_path: "/library/reserved.epub" } ].each do |attributes|
      upload = create_manual_match
      upload.update!(attributes)
      book_id = upload.book_id

      assert_raises(ActiveRecord::RecordNotDestroyed) { upload.destroy! }

      assert Upload.exists?(upload.id)
      assert Book.exists?(book_id)
    end
  end

  test "replacement and deletion preserve manual creations adopted by another owner" do
    [ :replace, :destroy ].each do |action|
      %i[acquired reservation upload request owned_item import_history post_processing].each do |adoption|
        upload = create_manual_match
        original = upload.book
        adopt_manual_book(original, adoption)

        if action == :replace
          upload.match_and_retry!(title: "Replacement for #{adoption}")
          assert upload.reload.pending?
        else
          upload.destroy!
          assert_not Upload.exists?(upload.id)
        end

        assert Book.exists?(original.id), "#{action} must preserve #{adoption}"
      end
    end
  end

  test "metadata cleanup errors occur before ingress removal and preserve both records" do
    path, size = UploadImportFileService.stage_ingress!(
      StringIO.new("preserve ingress"), "manual-cleanup-#{SecureRandom.hex(8)}.epub", max_bytes: 1.megabyte
    )
    upload = create_manual_match
    upload.update!(file_path: path, file_size: size)
    book_id = upload.book_id
    failure = ->(book) { raise IOError, "Metadata deletion failed" if book.id == book_id }
    Book.set_callback(:destroy, :before, failure)

    assert_raises(IOError) { upload.destroy! }

    assert_equal "preserve ingress", File.binread(path)
    assert_equal book_id, upload.reload.book_id
    assert Book.exists?(book_id)
  ensure
    Book.skip_callback(:destroy, :before, failure) if failure
    UploadImportFileService.discard_ingress!(path) if path
  end

  test "destroy removes only a private browser ingress file" do
    path, size = UploadImportFileService.stage_ingress!(
      StringIO.new("temporary ingress"),
      "upload-model-#{SecureRandom.hex(8)}.epub",
      max_bytes: 1.megabyte
    )
    upload = Upload.create!(
      user: users(:one),
      original_filename: "temporary.epub",
      file_path: path,
      file_size: size,
      status: :pending
    )

    upload.destroy!

    assert_not File.exist?(path)
  ensure
    FileUtils.rm_f(path) if path
  end

  test "destroy never unlinks an unreserved non-ingress pathname" do
    root = Dir.mktmpdir("upload-model-library")
    library_path = File.join(root, "library.epub")
    File.binwrite(library_path, "library bytes")
    upload = Upload.create!(
      user: users(:one),
      original_filename: "library.epub",
      file_path: library_path,
      status: :failed
    )

    upload.destroy!

    assert_equal "library bytes", File.binread(library_path)
  ensure
    FileUtils.rm_rf(root) if root
  end

  test "destroy aborts while an ordinary recovery reservation is present" do
    root = Dir.mktmpdir("upload-model-reservation")
    source = File.join(root, "source.epub")
    destination = File.join(root, "library", "reserved.epub")
    File.binwrite(source, "reserved bytes")
    upload = Upload.create!(
      user: users(:one),
      original_filename: "reserved.epub",
      file_path: source,
      file_size: File.size(source),
      status: :failed,
      destination_path: destination,
      destination_root: File.realpath(root),
      destination_configured_root: root,
      library_path: destination,
      content_sha256: Digest::SHA256.file(source).hexdigest,
      cleanup_source_path: File.realpath(source)
    )

    assert_raises(ActiveRecord::RecordNotDestroyed) { upload.destroy! }

    assert Upload.exists?(upload.id)
    assert_equal "reserved bytes", File.binread(source)
  ensure
    FileUtils.rm_rf(root) if root
  end

  test "destroy aborts while the upload owns a Book acquisition reservation" do
    book = Book.create!(title: "Upload-owned reservation", book_type: :ebook)
    upload = Upload.create!(
      user: users(:one),
      book: book,
      original_filename: "reserved.epub",
      file_path: "/tmp/upload-owned-reservation.epub",
      status: :failed
    )
    token = SecureRandom.hex(16)
    upload.update!(book_reservation_token: token)
    book.update!(
      acquisition_reservation_token: token,
      acquisition_reservation_owner_type: "Upload",
      acquisition_reservation_owner_id: upload.id
    )

    assert_raises(ActiveRecord::RecordNotDestroyed) { upload.destroy! }

    assert Upload.exists?(upload.id)
    assert book.reload.acquisition_reserved?
  end

  private

  def create_manual_match(status: :failed)
    upload = Upload.create!(user: users(:two), original_filename: "manual.epub", status: :failed)
    upload.match_and_retry!(title: "Manual creation #{SecureRandom.hex(4)}")
    upload.update!(status: status)
    upload
  end

  def adopt_manual_book(book, adoption)
    case adoption
    when :acquired
      book.update!(file_path: "/library/adopted.epub")
    when :reservation
      book.update!(acquisition_reservation_token: "other-owner-#{book.id}",
        acquisition_reservation_owner_type: "Download", acquisition_reservation_owner_id: book.id)
    when :upload
      Upload.create!(user: users(:one), original_filename: "shared.epub", status: :completed, book: book)
    when :request, :post_processing
      request = Request.create!(user: users(:one), book: book, status: :processing)
      if adoption == :post_processing
        request.downloads.create!(name: book.title, status: :completed, post_processing_job_id: "book-recovery-owner")
        assert book.post_processing_recovery_pending?
      end
    when :owned_item, :import_history
      connection = OwnedLibraryConnection.first || OwnedLibraryConnection.create!(enabled: false)
      item = connection.owned_library_items.create!(external_id: "B0MANUAL#{book.id}", title: book.title,
        ownership_type: "purchased", book: adoption == :owned_item ? book : nil)
      item.owned_media_imports.create!(created_book: book, status: "completed") if adoption == :import_history
    end
  end
end
