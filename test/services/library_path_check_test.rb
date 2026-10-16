# frozen_string_literal: true

require "test_helper"

class LibraryPathCheckTest < ActiveSupport::TestCase
  test "accepts a qBittorrent save path that maps inside the download directory" do
    Dir.mktmpdir do |local_path|
      FileUtils.mkdir_p(File.join(local_path, "books"))

      message = LibraryPathCheck.qbittorrent_message(
        save_path: "/mnt/torrents/books",
        category_save_path: nil,
        category: nil,
        local_path: local_path,
        remote_path: "/mnt/torrents"
      )

      assert_nil message
    end
  end

  test "does not warn when qBittorrent has not created the category folder yet" do
    Dir.mktmpdir do |local_path|
      message = LibraryPathCheck.qbittorrent_message(
        save_path: local_path,
        category_save_path: "",
        category: "shelfarr",
        local_path: local_path,
        remote_path: ""
      )

      assert_nil message
    end
  end

  test "warns when the mapped qBittorrent save path is outside the download directory" do
    Dir.mktmpdir do |local_path|
      message = LibraryPathCheck.qbittorrent_message(
        save_path: "/mnt/torrents/complete",
        category_save_path: nil,
        category: nil,
        local_path: local_path,
        remote_path: ""
      )

      assert_equal(
        "qBittorrent save path /mnt/torrents/complete maps to /mnt/torrents/complete. " \
          "That path is not inside /downloads or does not exist.",
        message
      )
    end
  end

  test "warns when an explicit category save path does not exist" do
    Dir.mktmpdir do |local_path|
      message = LibraryPathCheck.qbittorrent_message(
        save_path: local_path,
        category_save_path: File.join(local_path, "missing-category"),
        category: "shelfarr",
        local_path: local_path,
        remote_path: ""
      )

      assert_includes message, "qBittorrent save path #{File.join(local_path, "missing-category")} maps to"
      assert_includes message, "That path is not inside /downloads or does not exist."
    end
  end

  test "warns when an Audiobookshelf folder differs from the import path" do
    library = AudiobookshelfClient::Library.new(
      id: "audio",
      name: "Audiobooks",
      folders: [ { "fullPath" => "/abs/audiobooks" } ],
      media_type: "book"
    )

    messages = LibraryPathCheck.audiobookshelf_messages(
      libraries: [ library ],
      audiobook_library_id: "audio",
      ebook_library_id: nil,
      audiobook_output_path: "/shelfarr/audiobooks",
      ebook_output_path: nil
    )

    assert_equal [
      "ABS folder is /abs/audiobooks; Shelfarr imports to /shelfarr/audiobooks. " \
        "Mount the same directory at the same path in both containers, or change the output path."
    ], messages
  end

  test "warns when Audiobookshelf does not report a folder" do
    library = AudiobookshelfClient::Library.new(
      id: "ebooks",
      name: "Ebooks",
      folders: [],
      media_type: "book"
    )

    messages = LibraryPathCheck.audiobookshelf_messages(
      libraries: [ library ],
      audiobook_library_id: nil,
      ebook_library_id: "ebooks",
      audiobook_output_path: nil,
      ebook_output_path: "/shelfarr/ebooks"
    )

    assert_equal [ "ABS did not report a folder." ], messages
  end

  test "accepts the same Audiobookshelf and Shelfarr path" do
    library = AudiobookshelfClient::Library.new(
      id: "audio",
      name: "Audiobooks",
      folders: [ { "fullPath" => "/books/audiobooks/" } ],
      media_type: "book"
    )

    messages = LibraryPathCheck.audiobookshelf_messages(
      libraries: [ library ],
      audiobook_library_id: "audio",
      ebook_library_id: nil,
      audiobook_output_path: "/books/audiobooks",
      ebook_output_path: nil
    )

    assert_empty messages
  end
end
