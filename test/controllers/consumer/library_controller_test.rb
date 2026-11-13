# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"

class Consumer::LibraryControllerTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  setup do
    prepare_consumer_library
    sign_in_as(users(:one))
  end
  teardown { FileUtils.remove_entry(@root) }

  test "the responsive consumer shelf opens real acquired items without creating an API credential" do
    assert_no_difference "APIToken.count" do
      get consumer_library_path
    end
    assert_response :success
    assert_select "h1", text: "Your library."
    assert_select "a[href=?]", consumer_publication_path(@ebook)
    assert_select "a[href=?]", consumer_publication_path(@audiobook)
    get consumer_publication_path(@ebook)
    assert_response :success
    assert_select "[data-controller=consumer-reader]"
    assert_select "script[data-consumer-reader-target=publication]", text: /\/read\/#{@ebook.id}\/assets\//
    assert_not_includes response.body, @root
  end

  test "the reading page is a text surface and binds the browser outbox to this account" do
    get consumer_publication_path(@ebook)
    assert_select ".consumer-header", count: 0
    assert_select "body.consumer-app--reading"
    assert_select "[data-consumer-reader-target=controls][hidden]"
    assert_select "[data-consumer-reader-target=reveal][aria-expanded=false][aria-controls=consumer-reader-controls]"
    publication = JSON.parse(css_select("script[data-consumer-reader-target=publication]").sole.text)
    assert_equal({ "account" => users(:one).id.to_s, "base" => "" }, publication.fetch("progress_scope"))
    get consumer_publication_path(@audiobook)
    assert_select ".consumer-header"
    assert_select ".consumer-audio-panel"
  end

  test "web media and progress use the current cookie session with the same asset and version rules" do
    asset = consumer_asset(@audiobook)
    get consumer_asset_path(@audiobook, asset.id), headers: { "Range" => "bytes=0-2" }
    assert_response :partial_content
    assert_equal "an ", response.body
    put consumer_progress_path(@audiobook), params: audio_progress(asset_id: asset.id), headers: { "X-Shelfarr-Account" => users(:one).id.to_s }, as: :json
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("progress").fetch("version")
    get consumer_library_path
    assert_select "#continue-heading", text: "Keep going"
    assert_select "body", text: /Resume at 0:17/
  end

  test "an old reader tab cannot upload its account's place after the cookie account changes" do
    asset = consumer_asset(@audiobook)
    original_account = users(:one).id.to_s
    sign_out
    sign_in_as(users(:two))
    assert_no_difference "ConsumerProgress.count" do
      put consumer_progress_path(@audiobook), params: audio_progress(asset_id: asset.id), headers: { "X-Shelfarr-Account" => original_account }, as: :json
      assert_response :unauthorized
      assert_equal "account_changed", response.parsed_body.fetch("error")
      put consumer_progress_path(@audiobook), params: audio_progress(asset_id: asset.id), as: :json
      assert_response :unauthorized
    end
    put consumer_progress_path(@audiobook), params: audio_progress(asset_id: asset.id), headers: { "X-Shelfarr-Account" => users(:two).id.to_s }, as: :json
    assert_response :success
    assert_equal users(:two).id, ConsumerProgress.find_by!(book: @audiobook).user_id
  end

  test "empty filtered shelves explain the filter and offer a reset" do
    get consumer_library_path(status: "finished", sort: "title")
    assert_response :success
    assert_select ".consumer-empty h3", text: "No stories match these filters"
    assert_select ".consumer-empty a[href=?]", consumer_library_path(sort: "title"), text: "Clear filters"
    assert_select ".consumer-empty a", text: "Find a book", count: 0
  end

  test "signed-out browsers cannot access the consumer library or stream" do
    asset = consumer_asset(@ebook)
    sign_out
    get consumer_library_path
    assert_redirected_to new_session_path
    get consumer_asset_path(@ebook, asset.id)
    assert_redirected_to new_session_path
  end
end
