# frozen_string_literal: true

require "test_helper"

class OwnedLibraryItemTest < ActiveSupport::TestCase
  setup do
    @connection = OwnedLibraryConnection.create!
  end

  test "formats creators and title" do
    item = @connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      subtitle: "A Subtitle",
      authors: [ "First Author", "Second Author" ],
      narrators: [ "Narrator" ],
      ownership_type: "purchased"
    )

    assert_equal "A Title: A Subtitle", item.display_title
    assert_equal "First Author, Second Author", item.author
    assert_equal "Narrator", item.narrator
    assert item.purchased?
  end

  test "uses trusted Amazon covers and expands cached picture identifiers" do
    item = @connection.owned_library_items.create!(
      external_id: "B012345680",
      title: "A Title",
      cover_url: "71YfEidUvAL"
    )

    assert_equal "https://m.media-amazon.com/images/I/71YfEidUvAL._SL500_.jpg",
      item.cover_image_url

    item.cover_url = "https://m.media-amazon.com/images/I/cover.jpg"
    assert_equal "https://m.media-amazon.com/images/I/cover.jpg", item.cover_image_url

    [
      "http://m.media-amazon.com/images/I/cover.jpg",
      "https://reader@m.media-amazon.com/images/I/cover.jpg",
      "https://m.media-amazon.com:444/images/I/cover.jpg",
      "https://m.media-amazon.com.attacker.test/images/I/cover.jpg",
      "https://127.0.0.1/images/I/cover.jpg",
      "https://m.media-amazon.com/private-service",
      "javascript:alert(1)"
    ].each do |unsafe_url|
      item.cover_url = unsafe_url
      assert_nil item.cover_image_url, unsafe_url
    end
  end

  test "requires external id to be unique within the connection" do
    @connection.owned_library_items.create!(external_id: "B012345678", title: "First")
    duplicate = @connection.owned_library_items.new(external_id: "B012345678", title: "Second")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:external_id], "has already been taken"
  end

  test "distinguishes subscription access from purchased ownership" do
    item = @connection.owned_library_items.create!(
      external_id: "B012345679",
      title: "Plus Title",
      ownership_type: "subscription"
    )

    assert item.subscription?
    assert_not item.purchased?
  end

  test "library visibility requires an active purchased audiobook on an enabled connection" do
    @connection.update!(enabled: true)
    visible = @connection.owned_library_items.create!(
      external_id: "B012345680",
      title: "Visible Purchase",
      ownership_type: "purchased",
      downloaded: true
    )
    subscription = @connection.owned_library_items.create!(
      external_id: "B012345681",
      title: "Subscription",
      ownership_type: "subscription"
    )
    inactive = @connection.owned_library_items.create!(
      external_id: "B012345682",
      title: "Inactive Purchase",
      ownership_type: "purchased",
      active: false
    )

    assert_includes OwnedLibraryItem.visible_in_library, visible
    assert_not_includes OwnedLibraryItem.visible_in_library, subscription
    assert_not_includes OwnedLibraryItem.visible_in_library, inactive

    visible.update!(book: books(:audiobook_acquired))
    assert_not_includes OwnedLibraryItem.visible_in_library, visible
  end

  test "linked books without a usable local path remain visible for backup" do
    @connection.update!(enabled: true)
    blank_book = Book.create!(title: "Blank Path", book_type: :audiobook, file_path: "")
    whitespace_book = Book.create!(title: "Whitespace Path", book_type: :audiobook, file_path: "  ")
    blank_item = @connection.owned_library_items.create!(
      external_id: "B012345683",
      title: "Blank Path",
      ownership_type: "purchased",
      book: blank_book
    )
    whitespace_item = @connection.owned_library_items.create!(
      external_id: "B012345684",
      title: "Whitespace Path",
      ownership_type: "purchased",
      book: whitespace_book
    )

    assert_includes OwnedLibraryItem.visible_in_library, blank_item
    assert_includes OwnedLibraryItem.visible_in_library, whitespace_item
  end

  test "cannot destroy a title while it owns queued backup work" do
    item = @connection.owned_library_items.create!(
      external_id: "B012345685",
      title: "Queued title"
    )
    item.owned_media_imports.create!(status: "pending", automatic: true)

    assert_not item.destroy
    assert item.persisted?
    assert_match(/cannot be deleted safely/, item.errors.full_messages.to_sentence)
  end
end
