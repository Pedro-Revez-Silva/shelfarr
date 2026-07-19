# frozen_string_literal: true

require "test_helper"

class UploadTest < ActiveSupport::TestCase
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
