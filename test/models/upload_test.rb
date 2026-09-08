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
end
