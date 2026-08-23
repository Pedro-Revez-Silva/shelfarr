# frozen_string_literal: true

require "test_helper"

class LibraryPathSafetyTest < ActiveSupport::TestCase
  test "all persisted upload destination validators reject internal namespaces" do
    root = Pathname(Dir.mktmpdir("library-path-safety"))

    LibraryPathSafety::INTERNAL_DIRECTORIES.each do |directory|
      destination = root.join(directory, "Book", "book.epub")

      assert_raises(UploadImportFileService::Error) do
        UploadImportFileService.send(:validate_path_within_root!, destination, root)
      end
      assert_raises(UploadZipImportFileService::Error) do
        UploadZipImportFileService.send(:validate_within_root!, destination, root)
      end
    end
  ensure
    FileUtils.rm_rf(root) if root
  end
end
