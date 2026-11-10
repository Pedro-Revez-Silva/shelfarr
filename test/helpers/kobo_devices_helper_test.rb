# frozen_string_literal: true

require "test_helper"

class KoboDevicesHelperTest < ActionView::TestCase
  Delivery = Struct.new(:progress_bridge, :progress_outbound)
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
      { "status" => "superseded", "percent" => 35.0 } => [ :warning, /newer place/, false ],
      place.merge("status" => "echo") => [ :ok, /reported the place Shelfarr sent it \(35%.*nothing new to share/, false ]
    }
    cases.each do |bridge, (tone, text, choosable)|
      notice = kobo_place_notice(Delivery.new(bridge), saved)
      assert_equal [ tone, choosable ], [ notice.tone, notice.choosable ], bridge.inspect
      assert_match text, notice.text, bridge.inspect
    end
    assert_match(/Kept a newer place from another device\. Kobo place/, kobo_place_notice(Delivery.new(place.merge("status" => "superseded")), nil).text)
  end

  test "every Shelfarr place status for a Kobo says why, and only comparable places can be sent by choice" do
    progress = ConsumerProgress.new(version: 3, client_mutation_id: "m")
    place = { "progress_version" => 3, "progress_mutation_id" => "m", "chapter" => 2, "chapters" => 9, "percent" => 40,
      "observed_at" => 2.hours.ago.utc.iso8601(3), "span" => "kobo.5.2" }
    cases = {
      nil => [ :info, /No Shelfarr reading place to send yet/, false ],
      place.merge("progress_version" => 2, "status" => "queued") => [ :info, /newer place for this book.*next sync/, false ],
      place.merge("status" => "queued") => [ :ok, /\(chapter 2 of 9, 40% of the book, read about 2 hours ago\) waits for this Kobo's next Wi-Fi sync.*nearest sentence/, false ],
      place.merge("status" => "queued", "reason" => "chosen") => [ :ok, /Your chosen Shelfarr place \(chapter 2 of 9, 40% of the book\)/, false ],
      place.merge("status" => "sent", "sent_at" => 3.minutes.ago.utc.iso8601(3)) => [ :ok, /sent with the sync 3 minutes ago.*next open the book/, false ],
      place.merge("status" => "at_place") => [ :ok, /already at Shelfarr's place/, false ],
      place.merge("status" => "kobo_place") => [ :info, /came from this Kobo, so it isn't sent back/, false ],
      place.merge("status" => "waiting", "reason" => "not_downloaded") => [ :info, /download the book before sending/, false ],
      place.merge("status" => "needs_choice", "reason" => "kobo_newer", "kobo_at" => 5.minutes.ago.utc.iso8601(3)) =>
        [ :choice, /newer place \(read 5 minutes ago\), so Shelfarr's older place/, true ],
      place.merge("status" => "needs_choice", "reason" => "same_time") => [ :choice, /same moment/, true ],
      place.merge("status" => "needs_choice", "reason" => "unknown_time") => [ :choice, /no reading time, so it can't be compared/, true ],
      place.merge("status" => "needs_choice", "reason" => "kobo_time_unknown") => [ :choice, /This Kobo's place has no reading time/, true ],
      place.merge("status" => "needs_choice", "reason" => "edition_unverified") => [ :choice, /previous edition.*current file/, true ],
      place.except("span").merge("status" => "needs_choice", "reason" => "same_time") => [ :warning, /same moment/, false ],
      place.merge("status" => "unsupported", "reason" => "plain_epub") => [ :warning, /plain EPUB was sent before.*Send again to deliver a Kobo edition/, false ],
      place.merge("status" => "unsupported", "reason" => "kepub_unavailable", "kepub_reason" => "not_well_formed") =>
        [ :warning, /couldn't safely prepare a Kobo edition of this EPUB \(a chapter isn't well-formed XHTML\), so the EPUB itself was sent/, false ],
      place.merge("status" => "unsupported", "reason" => "different_edition") => [ :warning, /different file of this book/, false ],
      place.merge("status" => "unsupported", "reason" => "file_changed") => [ :warning, /Send it again/, false ],
      place.merge("status" => "unsupported", "reason" => "location_not_in_edition") => [ :warning, /chapter this edition doesn't have/, false ],
      place.merge("status" => "unsupported", "reason" => "no_kobo_spans") => [ :warning, /no Kobo sentence markers/, false ],
      place.merge("status" => "unsupported", "reason" => "not_an_ebook") => [ :warning, /isn't a text place/, false ],
      place.merge("status" => "unsupported", "reason" => "unsafe_resource") => [ :warning, /too large or can't be read safely/, false ],
      place.merge("status" => "unavailable") => [ :warning, /couldn't check this book's file/, false ]
    }
    cases.each do |outbound, (tone, text, choosable)|
      notice = kobo_outbound_notice(Delivery.new(nil, outbound), progress)
      assert_equal [ tone, choosable ], [ notice.tone, notice.choosable ], outbound.inspect
      assert_match text, notice.text, outbound.inspect
    end
    assert_match(/No Shelfarr reading place/, kobo_outbound_notice(Delivery.new(nil, place.merge("status" => "queued")), nil).text)
  end
end
