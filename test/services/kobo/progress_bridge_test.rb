# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_test_helper"

class Kobo::ProgressBridgeTest < ActiveSupport::TestCase
  include KoboTestHelper

  PACKAGE = <<~XML
    <package version="3.0"><manifest>
      <item id="c1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
      <item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
      <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
    </manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
  XML

  setup do
    prepare_kobo_book
    write_epub(@path, package: PACKAGE, extra: { "OEBPS/Text/chapter 1.xhtml" => "<html/>", "OEBPS/Text/ch2.xhtml" => "<html/>" })
    @device.update!(share_progress: true)
    @delivery = @device.send_book!(@book)
    @delivery.update!(last_download_at: 1.day.ago)
    @user = users(:one)
    @asset_id = Consumer::LibraryAssets.new(@book).list.sole.id
  end

  teardown { FileUtils.remove_entry(@root) }

  def bookmark(source: "OEBPS/Text/ch2.xhtml", at: 10.minutes.ago, percent: 42, chapter: 50)
    { "LastModified" => at&.utc&.strftime("%Y-%m-%dT%H:%M:%S.%7NZ"), "ProgressPercent" => percent,
      "ContentSourceProgressPercent" => chapter, "Location" => { "Source" => source, "Type" => "KoboSpan", "Value" => "kobo.3.1" } }.compact
  end

  def bridge(mark)
    Kobo::ProgressBridge.new(@delivery.reload).call(mark)
  end

  def progress
    @user.consumer_progresses.find_by(book: @book)
  end

  test "a chapter place becomes shared progress for this edition at the Kobo's own reading time" do
    read_at = 3.hours.ago
    travel_to(1.hour.from_now) do
      assert_equal "shared", bridge(bookmark(at: read_at))["status"]
    end
    saved = progress
    assert_equal @asset_id, saved.asset_id
    assert_equal({ "href" => "OEBPS/Text/ch2.xhtml", "type" => "application/xhtml+xml",
      "locations" => { "progression" => 0.5, "totalProgression" => 0.42 } }, saved.locator)
    assert_equal read_at.utc.floor(3), saved.observed_at
    assert_not saved.locator["locations"].key?("cfi"), "Kobo span values are never presented as an exact locator"

    assert_no_changes -> { progress.attributes } do
      assert_equal "shared", bridge(bookmark(at: read_at))["status"]
    end
  end

  test "Kobo's content-ID and package-relative spellings resolve to the same spine resource" do
    [ "OEBPS/Text/ch2.xhtml#kobo.1.1", "Text/ch2.xhtml", "#{@delivery.entitlement_id}!!OEBPS/Text/ch2.xhtml",
      "#{@delivery.entitlement_id}!OEBPS!Text/ch2.xhtml", "/OEBPS/Text/ch2.xhtml" ].each_with_index do |source, index|
      result = bridge(bookmark(source: source, at: (20 - index).minutes.ago))
      assert_equal "shared", result["status"], source
      assert_equal "OEBPS/Text/ch2.xhtml", progress.locator["href"]
    end
    bridge(bookmark(source: "OEBPS/Text/chapter 1.xhtml", at: 1.minute.ago))
    assert_equal "OEBPS/Text/chapter%201.xhtml", progress.locator["href"], "the manifest spelling is what web readers save"
  end

  test "a later place from another device is kept and the older Kobo place is offered as a choice" do
    Consumer::ProgressWriter.new(user: @user, book: @book).call("asset_id" => @asset_id, "expected_version" => 0,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => 1.minute.ago.utc.iso8601(3),
      "locator" => { "href" => "OEBPS/Text/chapter%201.xhtml", "locations" => { "totalProgression" => 0.1 } })
    result = bridge(bookmark(at: 1.hour.ago))
    assert_equal "superseded", result["status"]
    assert_equal "OEBPS/Text/chapter%201.xhtml", progress.locator["href"]
    assert_equal "OEBPS/Text/ch2.xhtml", @delivery.reload.progress_bridge.dig("locator", "href"), "the unapplied place is preserved"

    travel_to(1.second.from_now) { Kobo::ProgressBridge.new(@delivery.reload).choose! }
    assert_equal "OEBPS/Text/ch2.xhtml", progress.locator["href"]
    assert_in_delta Time.current, progress.observed_at, 5, "an explicit choice is new activity at the time of the choice"
    assert_equal %w[shared chosen], @delivery.reload.progress_bridge.values_at("status", "reason")
  end

  test "equal or unknown saved times are not resolved automatically" do
    at = 5.minutes.ago
    Consumer::ProgressWriter.new(user: @user, book: @book).call("asset_id" => @asset_id, "expected_version" => 0,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => at.utc.iso8601(3),
      "locator" => { "href" => "OEBPS/Text/chapter%201.xhtml", "locations" => {} })
    assert_equal %w[needs_choice same_time], bridge(bookmark(at: at)).values_at("status", "reason")

    progress.update!(observed_at: nil)
    assert_equal %w[needs_choice saved_time_unknown], bridge(bookmark(at: 1.minute.ago)).values_at("status", "reason")
    assert_equal "OEBPS/Text/chapter%201.xhtml", progress.locator["href"]
  end

  test "places without a usable time or location are kept with their reason and never stamped with sync time" do
    assert_equal "unknown_time", bridge(bookmark(at: nil))["status"]
    assert_equal "unknown_time", bridge(bookmark.merge("LastModified" => "2026-11-09T10:00:00"))["status"]
    assert_equal "unknown_time", bridge(bookmark.merge("LastModified" => "1999-01-01T00:00:00Z"))["status"]
    assert_equal "clock_ahead", bridge(bookmark(at: 1.hour.from_now))["status"]
    assert_equal %w[unsupported no_location], bridge(bookmark.except("Location"))&.values_at("status", "reason")
    assert_equal "no_place", bridge({ "LastModified" => Time.current.iso8601, "ProgressPercent" => 0 })["status"]
    assert_equal %w[unsupported location_not_in_edition], bridge(bookmark(source: "OEBPS/Text/missing.xhtml")).values_at("status", "reason")
    assert_equal %w[unsupported location_not_in_edition], bridge(bookmark(source: "OEBPS/cover.png")).values_at("status", "reason")
    assert_equal %w[unsupported location_not_in_edition], bridge(bookmark(source: "../../etc/passwd")).values_at("status", "reason")
    assert_equal %w[unsupported location_not_in_edition], bridge(bookmark(source: "OEBPS/Text/%FF.xhtml")).values_at("status", "reason")
    assert_equal %w[unsupported location_not_in_edition], bridge(bookmark(source: "OEBPS\\Text\\ch2.xhtml")).values_at("status", "reason")
    assert_equal %w[unsupported invalid_percent], bridge(bookmark(percent: 140)).values_at("status", "reason")
    assert_nil progress
  end

  test "a changed library file is a different edition and never receives the old place" do
    File.rename(@path, "#{@path}.old")
    write_epub(@path, package: PACKAGE, extra: { "OEBPS/Text/chapter 1.xhtml" => "<p/>", "OEBPS/Text/ch2.xhtml" => "<p/>" })
    assert_equal "edition_changed", bridge(bookmark)["status"]
    assert_nil progress
    @device.send_book!(@book)
    assert_nil @delivery.reload.progress_bridge
  end

  test "a queued edition cannot receive a bookmark before its first download" do
    @delivery.update!(last_download_at: nil)
    assert_equal %w[edition_changed not_downloaded], bridge(bookmark).values_at("status", "reason")
    assert_nil progress
  end

  test "replacement downloads and later resends never manufacture edition proof for old bookmarks" do
    original_entitlement = @delivery.entitlement_id
    File.rename(@path, "#{@path}.old")
    write_epub(@path, package: PACKAGE, extra: { "OEBPS/Text/chapter 1.xhtml" => "<p>New text</p>", "OEBPS/Text/ch2.xhtml" => "<p>New text</p>" })
    replacement = @device.send_book!(@book)
    assert_equal original_entitlement, replacement.entitlement_id
    assert replacement.progress_generation_ambiguous?
    assert_equal "edition_changed", bridge(bookmark)["status"]
    assert_nil progress
    replacement.update!(last_download_at: Time.current)
    assert_equal %w[needs_choice edition_unverified], bridge(bookmark).values_at("status", "reason")
    assert_nil progress
    assert @device.send_book!(@book).progress_generation_ambiguous?
    assert_equal "needs_choice", bridge(bookmark(at: Time.current))["status"]
    Kobo::ProgressBridge.new(@delivery.reload).choose!
    assert_equal Consumer::LibraryAssets.new(@book).list.sole.id, progress.asset_id
  end

  test "a place is not shared when the listed asset is not the delivered file generation" do
    listed = Consumer::LibraryAssets.new(@book).list.sole
    other = listed.with(inode: listed.inode + 1)
    Consumer::LibraryAssets.stub(:new, ->(*) { Struct.new(:list).new([ other ]) }) do
      assert_equal %w[edition_changed not_a_current_asset], bridge(bookmark).values_at("status", "reason")
    end
    assert_nil progress
  end

    test "a reader that does not share places changes nothing" do
    @device.update!(share_progress: false)
    assert_nil bridge(bookmark)
    assert_nil progress
    assert_nil @delivery.reload.progress_bridge
  end

  test "an unexpected failure keeps the Kobo request working and records nothing about the place" do
    Consumer::LibraryAssets.stub(:new, ->(*) { raise "private/path" }) do
      assert_equal "unavailable", bridge(bookmark)["status"]
    end
    assert_not @delivery.reload.progress_bridge.to_json.include?("private/path")
  end

  test "this reader's own shared and chosen places stay recognisable after later notices and resends" do
    bridge(bookmark(at: 2.hours.ago))
    shared = progress
    assert Kobo::ProgressBridge.written_by?(@delivery.reload, shared)
    assert_equal "superseded", bridge(bookmark(source: "Text/chapter%201.xhtml", at: 3.hours.ago))["status"]
    @device.send_book!(@book)
    assert Kobo::ProgressBridge.written_by?(@delivery.reload, shared), "a later notice or a resend of the same file keeps the record"

    Consumer::ProgressWriter.new(user: @user, book: @book).call("asset_id" => @asset_id, "expected_version" => shared.version,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => 1.minute.ago.utc.iso8601(3),
      "locator" => { "href" => "OEBPS/Text/chapter%201.xhtml", "locations" => {} })
    assert_not Kobo::ProgressBridge.written_by?(@delivery.reload, progress), "another device's place is not this reader's"
    assert_not Kobo::ProgressBridge.written_by?(@delivery, nil)
    assert_operator Array(@delivery.progress_bridge["mutations"]).size, :<=, Kobo::ProgressBridge::MUTATION_HISTORY
  end
end
