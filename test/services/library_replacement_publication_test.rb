# frozen_string_literal: true

require "test_helper"

class LibraryReplacementPublicationTest < ActiveSupport::TestCase
  test "publication journal accepts another file after a thousand reused entries" do
    book = Book.create!(title: "Long Audiobook", author: "Narrator", book_type: :audiobook)
    request = Request.create!(book: book, user: users(:one), status: :processing)
    download = request.downloads.create!(name: book.title, status: :completed, progress: 100)
    paths = Array.new(1_000) { |index| "/library/Long Audiobook/chapter-#{index}.mp3" }
    download.update!(library_replacement_state: JSON.generate("published_paths" => paths))

    recorded = LibraryReplacement.record_published_path!(
      download,
      "/library/Long Audiobook/chapter-1000.mp3"
    )

    assert_equal true, recorded
    publication = LibraryReplacement.load(download)
    assert_instance_of LibraryReplacement::Publication, publication
    assert_equal 1_001, publication.published_paths.size
    assert_includes publication.published_paths, "/library/Long Audiobook/chapter-1000.mp3"
  end
end
