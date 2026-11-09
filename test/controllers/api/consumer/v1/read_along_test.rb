# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/consumer_test_helper"
require_relative "../../../../test_helpers/read_along_fixtures"

class API::Consumer::V1::ReadAlongTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include ReadAlongFixtures

  FEATURES = { "X-Shelfarr-Reader-Features" => "read-along" }.freeze

  setup do
    prepare_consumer_library
    Consumer::ReadAlong.forget_all
    write_read_along_epub(@epub_path)
    @asset = Consumer::LibraryAssets.new(@ebook).list.first
  end
  teardown { FileUtils.remove_entry(@root) if @root && File.exist?(@root) }

  test "installed clients keep their exact projection; declaring the feature adds only a summary" do
    get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers
    legacy = response.parsed_body
    assert_not legacy.fetch("assets").sole.key?("read_along")
    assert_includes response.headers["Vary"], "X-Shelfarr-Reader-Features"

    get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers.merge(FEATURES)
    declared = response.parsed_body
    summary = declared.fetch("assets").sole.delete("read_along")
    assert_equal legacy, declared
    assert_equal "available", summary.fetch("status")
    assert_equal "/api/consumer/v1/library/#{@ebook.id}/assets/#{@asset.id}/read_along", summary.fetch("manifest_url")

    # Unknown features are ignored; malformed declarations are refused.
    get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers.merge("X-Shelfarr-Reader-Features" => "read-along, future-thing")
    assert_response :success
    assert response.parsed_body.fetch("assets").sole.key?("read_along")
    [ "", "Read-Along", "read along", "x" * 200 ].each do |value|
      get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers.merge("X-Shelfarr-Reader-Features" => value)
      assert_response :bad_request, value.inspect
    end

    # Listings are unchanged; read-along is a detail of one publication.
    get "/api/consumer/v1/library", headers: @headers.merge(FEATURES)
    assert response.parsed_body.fetch("items").none? { |item| item.fetch("assets").any? { |asset| asset.key?("read_along") } }
  end

  test "the API manifest gives native clients EPUB hrefs, exact audio assets and transfer-ready URLs" do
    get "/api/consumer/v1/library/#{@ebook.id}/assets/#{@asset.id}/read_along", headers: @headers
    assert_response :success
    manifest = response.parsed_body
    assert_equal %w[version generation source ebook_asset_id package_path text audio cue_fields cues coverage resources resources_bytes publication_id manifest_url resources_url].sort,
      manifest.keys.sort
    track = manifest.fetch("audio").sole
    assert_equal "epub_resource", track.fetch("kind")
    assert_equal "OEBPS/audio/narration.mp3", track.fetch("href")
    get track.fetch("url"), headers: @headers.merge("Range" => "bytes=0-9")
    assert_response :partial_content
    assert_equal tone_bytes.byteslice(0, 10), response.body.b

    write_read_along_epub(@epub_path, overlay: false)
    FileUtils.cp(TONES, @audio_path)
    Consumer::ReadAlong::Import.new(ebook: @ebook, audiobook: @audiobook).call(read_along_document(epub_path: @epub_path, audio_path: @audio_path))
    asset = Consumer::LibraryAssets.new(@ebook).list.first
    audio_asset = Consumer::LibraryAssets.new(@audiobook).list.first
    get "/api/consumer/v1/library/#{@ebook.id}/assets/#{asset.id}/read_along", headers: @headers
    track = response.parsed_body.fetch("audio").sole
    assert_equal({ "kind" => "publication_asset", "publication_id" => @audiobook.id.to_s, "asset_id" => audio_asset.id,
      "filename" => File.basename(@audio_path), "media_type" => "audio/mpeg", "size_bytes" => tone_bytes.bytesize,
      "url" => "/api/consumer/v1/library/#{@ebook.id}/assets/#{asset.id}/read_along/audio/#{audio_asset.id}",
      "content_url" => "/api/consumer/v1/library/#{@audiobook.id}/assets/#{audio_asset.id}" }, track)
    post "/api/consumer/v1/library/#{@audiobook.id}/assets/#{audio_asset.id}/transfer_grant", headers: @headers
    assert_response :created
  end

  test "the manifest needs the library read scope" do
    token, raw = APIToken.issue!(name: "Requests only", user: users(:one), scopes: %w[requests:read])
    get "/api/consumer/v1/library/#{@ebook.id}/assets/#{@asset.id}/read_along", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :forbidden
    get "/api/consumer/v1/library/#{@ebook.id}/assets/#{@asset.id}/read_along/resources/OEBPS/chapter1.xhtml"
    assert_response :unauthorized
    assert token
  end
end
