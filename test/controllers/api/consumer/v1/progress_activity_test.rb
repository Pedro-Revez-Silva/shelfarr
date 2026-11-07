# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/consumer_test_helper"

# Activity-time reconciliation. Two devices of one account mean two tokens.
# The client steps after a 409 follow docs/consumer-api.md: newer local
# activity rebases with a new UUID and its original observed_at; older local
# activity adopts the server copy.
class API::Consumer::V1::ProgressActivityTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  setup do
    prepare_consumer_library
    _, raw = APIToken.issue!(name: "Second device", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES)
    @phone = @headers
    @tablet = { "Authorization" => "Bearer #{raw}" }
    @url = "/api/consumer/v1/library/#{@audiobook.id}/progress"
    @earlier = 3.hours.ago.utc.floor.iso8601(3)
    @later = (1.hour.ago.utc.floor + 0.25).iso8601(3)
  end
  teardown { FileUtils.remove_entry(@root) }

  test "observed_at is normalized to UTC milliseconds and kept apart from the receipt time" do
    put @url, params: audio_progress.merge(observed_at: "2025-11-07T10:15:30.123456+01:00"), headers: @phone, as: :json
    assert_response :success
    progress = response.parsed_body.fetch("progress")
    assert_equal "2025-11-07T09:15:30.123Z", progress.fetch("observed_at")
    assert_not_equal progress.fetch("observed_at"), progress.fetch("updated_at")
    get @url, headers: @tablet
    assert_equal "2025-11-07T09:15:30.123Z", response.parsed_body.dig("progress", "observed_at")
  end

  test "legacy writes and rows keep an unknown activity time instead of the upload time" do
    put @url, params: audio_progress, headers: @phone, as: :json
    assert_response :success
    assert response.parsed_body.fetch("progress").key?("observed_at")
    assert_nil response.parsed_body.dig("progress", "observed_at")
    assert_nil users(:one).consumer_progresses.find_by!(book: @audiobook).observed_at
    get "/api/consumer/v1/library/#{@audiobook.id}", headers: @phone
    assert_nil response.parsed_body.dig("progress", "observed_at")
  end

  test "both arrival orders of two offline devices keep the later activity even after a backward seek" do
    # The phone listened further earlier; the tablet later sought back.
    phone = audio_progress(seconds: 900).merge(observed_at: @earlier)
    tablet = audio_progress(seconds: 120).merge(observed_at: @later)

    [ [ phone, @phone, tablet, @tablet ], [ tablet, @tablet, phone, @phone ] ].each do |first, first_device, second, second_device|
      users(:one).consumer_progresses.delete_all
      put @url, params: first, headers: first_device, as: :json
      assert_response :success
      put @url, params: second, headers: second_device, as: :json
      assert_response :conflict
      remote = response.parsed_body.fetch("progress")
      if Time.iso8601(second.fetch(:observed_at)) > Time.iso8601(remote.fetch("observed_at"))
        put @url, params: second.merge(expected_version: remote.fetch("version"), client_mutation_id: SecureRandom.uuid), headers: second_device, as: :json
        assert_response :success
      else
        # A careless rebase of the older activity still cannot replace it.
        put @url, params: second.merge(expected_version: remote.fetch("version"), client_mutation_id: SecureRandom.uuid), headers: second_device, as: :json
        assert_response :conflict
      end
      saved = users(:one).consumer_progresses.find_by!(book: @audiobook)
      assert_equal 120, saved.position_seconds
      assert_equal Time.iso8601(@later), saved.observed_at
    end
  end

  test "stale activity sent with the current version is refused with the canonical place" do
    put @url, params: audio_progress(seconds: 50).merge(observed_at: @later), headers: @tablet, as: :json
    assert_response :success
    put @url, params: audio_progress(version: 1, seconds: 400).merge(observed_at: @earlier), headers: @phone, as: :json
    assert_response :conflict
    assert_equal "progress_conflict", response.parsed_body.fetch("error")
    assert_equal 1, response.parsed_body.dig("progress", "version")
    assert_equal @later, response.parsed_body.dig("progress", "observed_at")
    assert_equal 50, users(:one).consumer_progresses.find_by!(book: @audiobook).position_seconds
  end

  test "a delayed retry repeats one mutation and never overwrites newer activity" do
    first = audio_progress(seconds: 30).merge(observed_at: @earlier)
    put @url, params: first, headers: @phone, as: :json
    assert_response :success
    travel 2.hours do
      put @url, params: first, headers: @phone, as: :json
      assert_response :success
      assert_equal 1, response.parsed_body.dig("progress", "version")
    end
    put @url, params: first.merge(observed_at: @later), headers: @phone, as: :json
    assert_response :conflict, "a reused UUID cannot carry a different activity time"
    put @url, params: audio_progress(version: 1, seconds: 75).merge(observed_at: @later), headers: @tablet, as: :json
    assert_response :success
    put @url, params: first, headers: @phone, as: :json
    assert_response :conflict
    assert_equal 75, response.parsed_body.dig("progress", "position_seconds")
    assert_equal 2, users(:one).consumer_progresses.find_by!(book: @audiobook).version
  end

  test "equal times need a choice for a different place and unknown times keep version-only rules" do
    put @url, params: audio_progress(seconds: 10).merge(observed_at: @later), headers: @phone, as: :json
    put @url, params: audio_progress(version: 1, seconds: 10).merge(observed_at: @later), headers: @tablet, as: :json
    assert_response :success, "the same place at the same time is not a conflict"
    put @url, params: audio_progress(version: 2, seconds: 11).merge(observed_at: @later), headers: @tablet, as: :json
    assert_response :conflict
    # An old client sends no time: its matching version still saves, and the
    # activity time becomes unknown rather than the upload time.
    put @url, params: audio_progress(version: 2, seconds: 12), headers: @tablet, as: :json
    assert_response :success
    assert_nil response.parsed_body.dig("progress", "observed_at")
    put @url, params: audio_progress(version: 3, seconds: 13).merge(observed_at: @earlier), headers: @phone, as: :json
    assert_response :success, "a known time may follow an unknown one"
    assert_equal @earlier, response.parsed_body.dig("progress", "observed_at")
  end

  test "the same place reached later advances the activity time so an in-between place cannot win" do
    middle = 2.hours.ago.utc.floor.iso8601(3)
    put @url, params: audio_progress(seconds: 120).merge(observed_at: @earlier), headers: @tablet, as: :json
    put @url, params: audio_progress(seconds: 120).merge(observed_at: @later), headers: @phone, as: :json
    assert_response :conflict
    put @url, params: audio_progress(version: 1, seconds: 120).merge(observed_at: @later), headers: @phone, as: :json
    assert_response :success, "newer activity at the same place is rebased, not marked clean"
    assert_equal [ 2, @later ], response.parsed_body.fetch("progress").values_at("version", "observed_at")
    put @url, params: audio_progress(version: 2, seconds: 30).merge(observed_at: middle), headers: @tablet, as: :json
    assert_response :conflict
    assert_equal 120, users(:one).consumer_progresses.find_by!(book: @audiobook).position_seconds
  end

  test "an explicit keep-this-device choice bypasses only the chronological guard" do
    put @url, params: audio_progress(seconds: 50).merge(observed_at: @later), headers: @tablet, as: :json
    choice = audio_progress(version: 1, seconds: 400).merge(observed_at: @earlier, resolve_conflict: true)
    put @url, params: choice.merge(expected_version: 0), headers: @phone, as: :json
    assert_response :conflict, "the choice still needs the exact current version"
    put @url, params: choice.merge(asset_id: "0" * 64), headers: @phone, as: :json
    assert_response :unprocessable_entity
    put @url, params: choice.merge(resolve_conflict: false), headers: @phone, as: :json
    assert_response :conflict
    put @url, params: choice, headers: @phone, as: :json
    assert_response :success
    assert_equal [ 400, 2, @earlier ], response.parsed_body.fetch("progress").values_at("position_seconds", "version", "observed_at")
    put @url, params: choice, headers: @phone, as: :json
    assert_response :success, "retrying the choice is idempotent"
    assert_equal 2, response.parsed_body.dig("progress", "version")
    _, raw = APIToken.issue!(name: "Library only", user: users(:one), scopes: [ "library:read" ])
    put @url, params: choice.merge(expected_version: 2, client_mutation_id: SecureRandom.uuid),
      headers: { "Authorization" => "Bearer #{raw}" }, as: :json
    assert_response :forbidden
  end

  test "invalid activity times or resolution flags are refused without erasing the saved place" do
    put @url, params: audio_progress(seconds: 64).merge(observed_at: @earlier), headers: @phone, as: :json
    assert_response :success
    [ { observed_at: "2026-11-07T10:00:00" }, { observed_at: "2026-11-07" }, { observed_at: "yesterday" },
      { observed_at: 1_762_500_000 }, { observed_at: { at: @later } }, { observed_at: [ @later ] },
      { observed_at: "2026-02-30T10:00:00Z" }, { observed_at: 10.minutes.from_now.utc.iso8601 },
      { resolve_conflict: "true" }, { resolve_conflict: 1 }, { resolve_conflict: [ true ] }, { resolve_conflict: { yes: true } } ].each do |extra|
      put @url, params: audio_progress(version: 1, seconds: 99).merge(extra), headers: @phone, as: :json
      assert_response :unprocessable_entity, extra.inspect
      assert_equal "invalid_progress", response.parsed_body.fetch("error")
    end
    saved = users(:one).consumer_progresses.find_by!(book: @audiobook)
    assert_equal [ 64, 1, Time.iso8601(@earlier) ], [ saved.position_seconds, saved.version, saved.observed_at ]
    put @url, params: audio_progress(version: 1, seconds: 99).merge(observed_at: 4.minutes.from_now.utc.iso8601(3), resolve_conflict: nil), headers: @phone, as: :json
    assert_response :success, "small clock skew is accepted"
  end

  test "web session writes follow the same activity rules" do
    sign_in_as(users(:one))
    web_url = "/read/#{@audiobook.id}/progress"
    put web_url, params: audio_progress(seconds: 5).merge(observed_at: @later), as: :json
    assert_response :success
    put web_url, params: audio_progress(version: 1, seconds: 900).merge(observed_at: @earlier), as: :json
    assert_response :conflict
    assert_equal @later, response.parsed_body.dig("progress", "observed_at")
    put web_url, params: audio_progress(version: 1, seconds: 900).merge(observed_at: "not a time"), as: :json
    assert_response :unprocessable_entity
  end

  test "continue orders saved places by actual activity rather than upload time" do
    ebook_asset = consumer_asset(@ebook).id
    put "/api/consumer/v1/library/#{@ebook.id}/progress", headers: @phone, as: :json, params: {
      asset_id: ebook_asset, expected_version: 0, client_mutation_id: SecureRandom.uuid, observed_at: @later,
      locator: { href: "OEBPS/chapter.xhtml", locations: { progression: 0.4 } } }
    assert_response :success
    travel 1.minute do
      # Uploaded later, but listened to earlier while offline.
      put @url, params: audio_progress.merge(observed_at: @earlier), headers: @tablet, as: :json
      assert_response :success
      get "/api/consumer/v1/continue", headers: @phone
      assert_equal [ @ebook.id.to_s, @audiobook.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    end
  end
end
