# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/consumer_test_helper"

class API::Consumer::V1::ProgressControllerTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  setup { prepare_consumer_library }
  teardown { FileUtils.remove_entry(@root) }

  test "audio progress is versioned per user and a retried mutation is idempotent" do
    url = "/api/consumer/v1/library/#{@audiobook.id}/progress"
    get url, headers: @headers
    assert_nil response.parsed_body.fetch("progress")
    values = audio_progress
    put url, params: values, headers: @headers, as: :json
    assert_response :success
    progress = response.parsed_body.fetch("progress")
    assert_equal 17.5, progress.fetch("position_seconds")
    assert_equal 1, progress.fetch("version")
    put url, params: values, headers: @headers, as: :json
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("progress").fetch("version")
    put url, params: values.merge(position_seconds: 25), headers: @headers, as: :json
    assert_response :conflict
    put url, params: audio_progress(seconds: 30), headers: @headers, as: :json
    assert_response :conflict
    assert_equal 17.5, response.parsed_body.fetch("progress").fetch("position_seconds")
    put url, params: audio_progress(version: 1, seconds: 30), headers: @headers, as: :json
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("progress").fetch("version")
    _, raw = APIToken.issue!(name: "Other user", user: users(:two), scopes: ConsumerDeviceGrant::SCOPES)
    get url, headers: { "Authorization" => "Bearer #{raw}" }
    assert_nil response.parsed_body.fetch("progress")
    assert_equal 30, users(:one).consumer_progresses.find_by!(book: @audiobook).position_seconds
  end

  test "ebook locators retain positions for their exact asset and HEAD cannot write state" do
    url = "/api/consumer/v1/library/#{@ebook.id}/progress"
    values = { asset_id: consumer_asset(@ebook).id, expected_version: 0, client_mutation_id: SecureRandom.uuid,
      locator: { href: "OEBPS/chapter.xhtml", type: "application/xhtml+xml", locations: { progression: 0.3, totalProgression: 0.2, position: 4 } } }
    assert_no_difference "ConsumerProgress.count" do
      head url, params: values, headers: @headers, as: :json
      assert_response :success
    end
    put url, params: values, headers: @headers, as: :json
    assert_response :success
    assert_equal "OEBPS/chapter.xhtml", response.parsed_body.fetch("progress").fetch("locator").fetch("href")
    get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers
    assert_equal 4, response.parsed_body.fetch("progress").fetch("locator").fetch("locations").fetch("position")
    File.rename(@epub_path, "#{@epub_path}.old")
    write_consumer_epub(@epub_path, chapter: "A different edition")
    put url, params: values.merge(expected_version: 1, client_mutation_id: SecureRandom.uuid), headers: @headers, as: :json
    assert_response :unprocessable_entity
    get "/api/consumer/v1/library/#{@ebook.id}", headers: @headers
    assert_not_equal response.parsed_body.fetch("assets").sole.fetch("id"), response.parsed_body.fetch("progress").fetch("asset_id")
  end

  test "validation rejects missing versions invalid positions and unsafe or oversized locators" do
    audio_url = "/api/consumer/v1/library/#{@audiobook.id}/progress"
    [ audio_progress(version: "0"), audio_progress(seconds: -1), audio_progress(seconds: "10"),
      audio_progress(seconds: 999_999_999), audio_progress(asset_id: "unknown"), audio_progress(mutation: "not-a-uuid") ].each do |values|
      put audio_url, params: values, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
    ebook_url = "/api/consumer/v1/library/#{@ebook.id}/progress"
    base = { asset_id: consumer_asset(@ebook).id, expected_version: 0, client_mutation_id: SecureRandom.uuid }
    [ { href: "https://attacker.example", locations: {} }, { href: "../private.xhtml", locations: {} },
      { href: "chapter.xhtml", locations: { progression: 1.1 } }, { href: "chapter.xhtml", locations: { position: 0 } },
      { href: "chapter.xhtml", locations: {}, text: { highlight: "x" * 17_000 } }, [] ].each do |locator|
      put ebook_url, params: base.merge(locator: locator), headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
    assert_empty users(:one).consumer_progresses
  end

  test "read-only credentials cannot change progress" do
    _, raw = APIToken.issue!(name: "Library only", user: users(:one), scopes: [ "library:read" ])
    put "/api/consumer/v1/library/#{@audiobook.id}/progress", params: audio_progress,
      headers: { "Authorization" => "Bearer #{raw}" }, as: :json
    assert_response :forbidden
    assert_equal "progress:write", response.parsed_body.fetch("required_scope")
  end
end
