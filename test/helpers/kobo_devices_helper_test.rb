# frozen_string_literal: true

require "test_helper"

class KoboDevicesHelperTest < ActionView::TestCase
  Delivery = Struct.new(:progress_bridge)
  Device = Struct.new(:store_status, :store_checked_at, :store_coexistence) do
    def store_coexistence? = store_coexistence
  end

  test "every Store outcome has an explanation" do
    expected = { nil => [ :info, /Waiting/ ], "ok" => [ :ok, /answered 2 minutes ago/ ],
      "unavailable" => [ :warning, /couldn't be reached.*Shelfarr books still synced/ ],
      "rejected" => [ :warning, /refused.*Shelfarr books still synced/ ],
      "authorization" => [ :warning, /sign in again.*same Kobo account/ ] }
    expected.each do |status, (tone, text)|
      notice = kobo_store_status(Device.new(status, 2.minutes.ago, true))
      assert_equal tone, notice.tone
      assert_match text, notice.text
    end
    assert_equal "Kobo Store + Shelfarr", kobo_mode_label(Device.new(nil, nil, true))
    assert_equal "Shelfarr books only", kobo_mode_label(Device.new(nil, nil, false))
  end

  test "every reading place status says why, and only comparable places can be chosen" do
    place = { "percent" => 35.0, "observed_at" => 3.hours.ago.utc.iso8601(3), "locator" => { "href" => "a" } }
    saved = ConsumerProgress.new(locator: { "locations" => { "totalProgression" => 0.8 } }, observed_at: 5.minutes.ago)
    cases = {
      nil => [ :info, /No Kobo reading place yet/, false ],
      { "status" => "no_place" } => [ :info, /No Kobo reading place yet/, false ],
      place.merge("status" => "shared") => [ :ok, /shared with Shelfarr: 35%, read about 3 hours ago/, false ],
      place.merge("status" => "shared", "reason" => "chosen") => [ :ok, /the Kobo place you chose \(35%/, false ],
      place.merge("status" => "superseded") => [ :choice, /newer place from another device \(80%, read 5 minutes ago\)/, true ],
      place.merge("status" => "needs_choice", "reason" => "same_time") => [ :choice, /same moment.*Shelfarr place: 80%/, true ],
      place.merge("status" => "needs_choice", "reason" => "saved_time_unknown") => [ :choice, /no reading time/, true ],
      place.merge("status" => "needs_choice", "reason" => "concurrent") => [ :choice, /while this one arrived/, true ],
      place.merge("status" => "needs_choice", "reason" => "edition_unverified") => [ :choice, /previous edition.*chapter and percentage fit the current file/, true ],
      place.merge("status" => "unknown_time") => [ :choice, /didn't say when/, true ],
      place.merge("status" => "clock_ahead") => [ :choice, /clock is ahead/, true ],
      { "status" => "unsupported", "reason" => "no_location", "percent" => 12.0 } => [ :warning, /only a percentage \(12%\)/, false ],
      { "status" => "unsupported", "reason" => "invalid_percent" } => [ :warning, /can't read/, false ],
      { "status" => "unsupported", "reason" => "location_not_in_edition" } => [ :warning, /doesn't match a chapter/, false ],
      { "status" => "edition_changed" } => [ :warning, /file changed after it was sent/, false ],
      { "status" => "edition_changed", "reason" => "not_downloaded" } => [ :warning, /Waiting for this reader to download/, false ],
      { "status" => "unavailable" } => [ :warning, /couldn't check/, false ],
      { "status" => "superseded", "percent" => 35.0 } => [ :warning, /newer place/, false ]
    }
    cases.each do |bridge, (tone, text, choosable)|
      notice = kobo_place_notice(Delivery.new(bridge), saved)
      assert_equal [ tone, choosable ], [ notice.tone, notice.choosable ], bridge.inspect
      assert_match text, notice.text, bridge.inspect
    end
    assert_match(/Kept a newer place from another device\. Kobo place/, kobo_place_notice(Delivery.new(place.merge("status" => "superseded")), nil).text)
  end
end
