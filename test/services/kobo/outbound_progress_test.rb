# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_test_helper"

class Kobo::OutboundProgressTest < ActiveSupport::TestCase
  include KoboTestHelper

  setup do
    prepare_kobo_book
    prepare_kobo_kepub
    @user = users(:one)
    @device.update!(share_progress: true, receive_progress: true)
    @delivery = @device.send_book!(@book)
    @delivery.update!(last_download_at: 1.day.ago)
    @asset_id = Consumer::LibraryAssets.new(@book).list.sole.id
    @first = sync(nil)
  end

  teardown { FileUtils.remove_entry(@root) }

  def sync(cursor, device = @device, token = @token)
    KoboSync.new(device.reload, endpoint: device.endpoint(token)).call(cursor)
  end

  # A place saved through the production consumer write path, as the web,
  # Android and iOS readers do.
  def read_in_shelfarr(href: "OEBPS/Text/ch2.xhtml", progression: 0.5, total: 0.5, at: 2.hours.ago, user: @user, **extra)
    current = user.consumer_progresses.find_by(book: @book)
    locator = { "href" => href, "type" => "application/xhtml+xml", "locations" => { "progression" => progression, "totalProgression" => total }.merge(extra) }
    Consumer::ProgressWriter.new(user: user, book: @book).call("asset_id" => @asset_id, "expected_version" => current&.version || 0,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => at&.utc&.iso8601(3), "locator" => locator)
  end

  def kobo_bookmark(span:, source: "OEBPS/Text/ch2.xhtml", at: Time.current, percent: 50)
    { "LastModified" => at.utc.strftime("%Y-%m-%dT%H:%M:%S.%7NZ"), "ProgressPercent" => percent, "ContentSourceProgressPercent" => 50,
      "Location" => { "Type" => "KoboSpan", "Source" => source, "Value" => span } }
  end

  # The Kobo uploading its bookmark exactly as KoboController#state stores it.
  def kobo_uploads(bookmark, delivery = @delivery)
    delivery.reload
    delivery.update_columns(reading_state: (delivery.reading_state || {}).merge("CurrentBookmark" => bookmark))
    Kobo::ProgressBridge.new(delivery).call(bookmark)
  end

  def progress
    @user.consumer_progresses.find_by(book: @book)
  end

  def state_items(result)
    result.items.filter_map { |item| item.dig("ChangedReadingState", "ReadingState") }
  end

  test "a Shelfarr place reaches a reader whose cursor is past the book as a state-only change at its reading time" do
    assert_equal "NewEntitlement", @first.items.sole.keys.sole
    revision, file_revision, downloaded = @delivery.reload.values_at(:revision_id, :file_sync_revision, :last_download_at)
    read_at = 2.hours.ago.utc.floor(3)
    saved = read_in_shelfarr(at: read_at)

    second = travel_to(1.hour.from_now) { sync(@first.token) }
    assert_equal [ "ChangedReadingState" ], second.items.map { |item| item.keys.sole }, "the book is not announced again"
    state = state_items(second).sole
    assert_equal @delivery.entitlement_id, state.fetch("EntitlementId")
    assert_equal({ "Type" => "KoboSpan", "Source" => "OEBPS/Text/ch2.xhtml", "Value" => "kobo.5.2" }, state.dig("CurrentBookmark", "Location"))
    assert_equal [ 50, 50 ], state.fetch("CurrentBookmark").values_at("ContentSourceProgressPercent", "ProgressPercent")
    assert_equal [ read_at.iso8601(3) ] * 3, [ state.dig("CurrentBookmark", "LastModified"), state["LastModified"], state["PriorityTimestamp"] ],
      "the bookmark carries when it was read, not when it synced"
    assert_equal "Reading", state.dig("StatusInfo", "Status")
    assert_equal [ revision, file_revision, downloaded ], @delivery.reload.values_at(:revision_id, :file_sync_revision, :last_download_at),
      "the entitlement and file are unchanged, so nothing is downloaded again"
    assert_equal "sent", @delivery.progress_outbound["status"]

    assert_no_changes -> { [ @device.reload.sync_revision, @delivery.reload.sync_revision ] } do
      third = sync(second.token)
      assert_empty third.items, "a sent place is not queued again"
      sync(second.token)
      Kobo::OutboundProgress.refresh(@device.reload)
    end
    assert_equal saved.attributes, progress.attributes, "syncing never changes Shelfarr's place or time"
  end

  test "the Kobo echoing the place it was sent creates no activity and is not sent back, later Kobo reading flows back" do
    saved = read_in_shelfarr(at: 2.hours.ago)
    second = sync(@first.token)
    span = state_items(second).sole.dig("CurrentBookmark", "Location", "Value")

    echo = kobo_bookmark(span: span, source: "#{@delivery.entitlement_id}!!OEBPS/Text/ch2.xhtml", at: 1.minute.ago)
    assert_equal "echo", kobo_uploads(echo)["status"]
    assert_equal saved.attributes, progress.attributes, "an echo is neither a new version nor a new time"
    assert_empty sync(second.token).items

    later = 30.seconds.ago.utc.floor(3)
    assert_equal "shared", kobo_uploads(kobo_bookmark(span: "kobo.1.2", source: "OEBPS/Text/ch3.xhtml", at: later))["status"]
    assert_equal [ saved.version + 1, "OEBPS/Text/ch3.xhtml", later ], [ progress.version, progress.locator["href"], progress.observed_at ]
    fourth = sync(second.token)
    assert_empty fourth.items, "this reader's own place is not sent back to it"
    assert_equal "kobo_place", @delivery.reload.progress_outbound["status"]
    assert_not Kobo::OutboundProgress.serve(@delivery, progress).last

    # A repeated upload of the same Kobo place is an idempotent retry.
    assert_no_changes -> { progress.attributes } do
      kobo_uploads(kobo_bookmark(span: "kobo.1.2", source: "OEBPS/Text/ch3.xhtml", at: later))
      assert_empty sync(fourth.token).items
    end
  end

  test "an echo of an older sent place never overwrites newer Shelfarr reading" do
    read_in_shelfarr(at: 3.hours.ago)
    second = sync(@first.token)
    old_span = state_items(second).sole.dig("CurrentBookmark", "Location", "Value")
    newer = read_in_shelfarr(href: "OEBPS/Text/ch3.xhtml", progression: 0.2, total: 0.8, at: 1.hour.ago)

    # The reader opens the book before its next sync and reports the old place with its own clock.
    assert_equal "echo", kobo_uploads(kobo_bookmark(span: old_span, at: 1.minute.ago))["status"]
    assert_equal newer.attributes, progress.attributes
    state = state_items(sync(second.token)).sole
    assert_equal [ "OEBPS/Text/ch3.xhtml", "kobo.2.1" ], state.dig("CurrentBookmark", "Location").values_at("Source", "Value")
  end

  test "a queued place which was never handed to the Kobo cannot suppress real Kobo reading" do
    saved = read_in_shelfarr(at: 2.hours.ago)
    Kobo::OutboundProgress.refresh(@device.reload)
    assert_equal "queued", @delivery.reload.progress_outbound["status"]

    read_at = 1.minute.ago.utc.floor(3)
    assert_equal "shared", kobo_uploads(kobo_bookmark(span: "kobo.5.2", at: read_at))["status"]
    assert_equal [ saved.version + 1, read_at ], [ progress.version, progress.observed_at ]
  end

  test "reading elsewhere on Kobo then returning to a sent sentence is genuine backward reading" do
    saved = read_in_shelfarr(at: 2.hours.ago)
    second = sync(@first.token)
    span = state_items(second).sole.dig("CurrentBookmark", "Location", "Value")
    assert_equal "echo", kobo_uploads(kobo_bookmark(span: span, at: 1.hour.ago))["status"]
    assert_equal "shared", kobo_uploads(kobo_bookmark(span: "kobo.1.2", source: "OEBPS/Text/ch3.xhtml", at: 30.minutes.ago))["status"]

    read_at = 1.minute.ago.utc.floor(3)
    assert_equal "shared", kobo_uploads(kobo_bookmark(span: span, at: read_at))["status"]
    assert_equal [ saved.version + 2, "OEBPS/Text/ch2.xhtml", read_at ],
      [ progress.version, progress.locator["href"], progress.observed_at ]
    assert_empty sync(second.token).items, "the reader's genuine backward place is not bounced back"
  end

  test "a queued place is withheld if its delivered file changes before serving" do
    read_in_shelfarr
    Kobo::OutboundProgress.refresh(@device.reload)
    assert_equal "queued", @delivery.reload.progress_outbound["status"]
    File.open(@path, "ab") { |file| file.write("changed after queueing") }

    assert_equal [ nil, false ], Kobo::OutboundProgress.serve(@delivery.reload, progress)
    assert_empty sync(@first.token).items
  end

  test "receiving a different Kobo place ends echo suppression even when inbound sharing is off" do
    read_in_shelfarr(at: 2.hours.ago)
    second = sync(@first.token)
    span = state_items(second).sole.dig("CurrentBookmark", "Location", "Value")
    @device.update!(share_progress: false)
    kobo_uploads(kobo_bookmark(span: "kobo.1.2", source: "OEBPS/Text/ch3.xhtml", at: 1.hour.ago))
    kobo_uploads(kobo_bookmark(span: span, at: 1.minute.ago))

    read_in_shelfarr(href: "OEBPS/Text/ch3.xhtml", at: 30.minutes.ago)
    assert_empty sync(second.token).items, "the newer Kobo return is genuine reading, even without importing it"
    assert_equal %w[needs_choice kobo_newer], @delivery.reload.progress_outbound.values_at("status", "reason")
  end

  test "an explicit choice can resolve an unknown Kobo time but cannot overwrite a subsequent Kobo place" do
    @device.update!(share_progress: false)
    unknown = kobo_bookmark(span: "kobo.1.2", source: "OEBPS/Text/ch3.xhtml").except("LastModified")
    kobo_uploads(unknown)
    saved = read_in_shelfarr
    assert_empty sync(@first.token).items
    assert_equal %w[needs_choice kobo_time_unknown], @delivery.reload.progress_outbound.values_at("status", "reason")

    Kobo::OutboundProgress.new(@delivery, progress).choose!
    state, shelfarr = Kobo::OutboundProgress.serve(@delivery.reload, progress)
    assert shelfarr, "the owner's explicit choice resolves the otherwise incomparable time"
    assert_equal "kobo.5.2", state.dig("CurrentBookmark", "Location", "Value")

    changed = unknown.deep_dup
    changed["Location"]["Value"] = "kobo.2.1"
    kobo_uploads(changed)
    assert_equal [ @delivery.reload.reading_state, false ], Kobo::OutboundProgress.serve(@delivery, progress),
      "the choice applies only to the Kobo place the owner saw"
    assert_equal saved.attributes, progress.attributes
  end

  test "intentional newer backward reading in Shelfarr is sent" do
    read_in_shelfarr(href: "OEBPS/Text/ch3.xhtml", progression: 0.9, total: 0.95, at: 3.hours.ago)
    second = sync(@first.token)
    read_in_shelfarr(href: "OEBPS/Text/chapter%201.xhtml", progression: 0, total: 0, at: 1.hour.ago)
    state = state_items(sync(second.token)).sole
    assert_equal [ "OEBPS/Text/chapter 1.xhtml", "kobo.1.1" ], state.dig("CurrentBookmark", "Location").values_at("Source", "Value")
    assert_equal 0, state.dig("CurrentBookmark", "ProgressPercent")
  end

  test "a newer genuine Kobo place wins and an older Shelfarr place waits for an explicit choice" do
    @device.update!(share_progress: false)
    kobo_uploads(kobo_bookmark(span: "kobo.2.1", source: "OEBPS/Text/ch3.xhtml", at: 10.minutes.ago))
    saved = read_in_shelfarr(at: 1.hour.ago)
    assert_empty sync(@first.token).items
    outbound = @delivery.reload.progress_outbound
    assert_equal %w[needs_choice kobo_newer], outbound.values_at("status", "reason")

    travel_to(1.second.from_now) { Kobo::OutboundProgress.new(@delivery, progress).choose! }
    state = state_items(sync(@first.token)).sole
    assert_in_delta Time.current, Time.iso8601(state.dig("CurrentBookmark", "LastModified")), 5, "a choice is new activity at the time of the choice"
    assert_equal "kobo.5.2", state.dig("CurrentBookmark", "Location", "Value")
    assert_equal saved.attributes, progress.attributes, "the choice never changes Shelfarr's own place or time"
  end

  test "a queued place is not served once the Kobo has genuinely read further" do
    @device.update!(share_progress: false)
    read_in_shelfarr(at: 1.hour.ago)
    Kobo::OutboundProgress.refresh(@device.reload)
    assert_equal "queued", @delivery.reload.progress_outbound["status"]
    kobo_uploads(kobo_bookmark(span: "kobo.3.1", source: "OEBPS/Text/ch3.xhtml", at: 1.minute.ago))
    assert_empty sync(@first.token).items
    state, shelfarr = Kobo::OutboundProgress.serve(@delivery.reload, progress)
    assert_not shelfarr
    assert_equal "kobo.3.1", state.dig("CurrentBookmark", "Location", "Value"), "GET state keeps the Kobo's newer place"
  end

  test "equal and unknown times, and the Kobo already at the place, are not sent automatically" do
    at = 1.hour.ago.utc.floor(3)
    @device.update!(share_progress: false)
    kobo_uploads(kobo_bookmark(span: "kobo.1.1", source: "OEBPS/Text/ch3.xhtml", at: at))
    read_in_shelfarr(at: at)
    assert_empty sync(@first.token).items
    assert_equal %w[needs_choice same_time], @delivery.reload.progress_outbound.values_at("status", "reason")

    read_in_shelfarr(at: nil)
    assert_empty sync(@first.token).items
    assert_equal %w[needs_choice unknown_time], @delivery.reload.progress_outbound.values_at("status", "reason")

    kobo_uploads(kobo_bookmark(span: "kobo.5.2", at: 2.hours.ago))
    read_in_shelfarr(at: 30.minutes.ago)
    assert_empty sync(@first.token).items
    assert_equal "at_place", @delivery.reload.progress_outbound["status"]
  end

  test "places are sent only while the reader opts in, checked when queued and again when served" do
    @device.update!(receive_progress: false)
    read_in_shelfarr
    assert_empty sync(@first.token).items
    assert_nil @delivery.reload.progress_outbound

    @device.update!(receive_progress: true)
    Kobo::OutboundProgress.refresh(@device.reload)
    assert_equal "queued", @delivery.reload.progress_outbound["status"]
    @device.update!(receive_progress: false)
    while_off = sync(@first.token)
    assert_empty while_off.items, "turning it off before the sync withdraws the place"
    assert_nil Kobo::OutboundProgress.serve(@delivery.reload, progress).first
    @device.update!(receive_progress: true)
    assert_equal 1, state_items(sync(while_off.token)).size, "re-enabling also reaches a cursor that advanced while it was off"
  end

  test "an opt-out during mapping is checked again inside the queue lock" do
    read_in_shelfarr
    stale = Kobo::OutboundProgress.new(@delivery, progress)
    KoboDevice.find(@device.id).update!(receive_progress: false)
    assert_no_changes -> { @device.reload.sync_revision } do
      stale.evaluate!
    end
    assert_nil @delivery.reload.progress_outbound
  end

  test "places stay with their owner and reach only that owner's opted-in readers" do
    other_user = users(:two)
    read_in_shelfarr(user: other_user, at: 1.hour.ago)
    assert_empty sync(@first.token).items, "another user's reading never moves this reader"

    off, off_token = KoboDevice.issue(user: @user, name: "Not opted in", base_url: @device.base_url)
    off.save!
    off.send_book!(@book).update!(last_download_at: 1.hour.ago)
    other, other_token = KoboDevice.issue(user: other_user, name: "Theirs", base_url: @device.base_url, receive_progress: true)
    other.save!
    other.send_book!(@book).update!(last_download_at: 1.hour.ago)
    off_cursor = sync(nil, off, off_token).token
    assert_nil sync(nil, off, off_token).items.sole.dig("NewEntitlement", "ReadingState")
    other_first = sync(nil, other, other_token)
    other_state = other_first.items.sole.dig("NewEntitlement", "ReadingState")
    assert_equal other.kobo_deliveries.sole.entitlement_id, other_state["EntitlementId"]
    assert_in_delta 1.hour.ago, Time.iso8601(other_state["LastModified"]), 5, "the other user's reader gets that user's own place"

    read_in_shelfarr(at: 10.minutes.ago)
    assert_equal 1, state_items(sync(@first.token)).size
    assert_empty sync(off_cursor, off, off_token).items
    assert_empty sync(other_first.token, other, other_token).items, "this owner's reading never moves the other user's reader"
  end

  test "a place read on one Kobo reaches the owner's other opted-in Kobo" do
    second_reader, token = KoboDevice.issue(user: @user, name: "Second", base_url: @device.base_url, receive_progress: true)
    second_reader.save!
    second_reader.send_book!(@book).update!(last_download_at: 1.hour.ago)
    cursor = sync(nil, second_reader, token).token
    kobo_uploads(kobo_bookmark(span: "kobo.1.2", source: "OEBPS/Text/ch3.xhtml", at: 5.minutes.ago, percent: 70))
    assert_empty sync(@first.token).items
    location = state_items(sync(cursor, second_reader, token)).sole.dig("CurrentBookmark", "Location")
    assert_equal [ "OEBPS/Text/ch3.xhtml", "kobo.3.2" ], location.values_at("Source", "Value"), "the chapter percentage is placed on that reader's real span"
  end

  test "plain EPUB deliveries and private household copies keep normal syncing and get no place" do
    # An .epub that already carries Kobo markup gets no prepared Kobo edition:
    # Kobo reads a plain .epub with its other engine, so no place is sent.
    @book.update!(file_path: File.join(@root, "Book.epub"))
    write_epub(@book.file_path, package: KEPUB_PACKAGE, extra: { "OEBPS/Text/chapter 1.xhtml" => kepub_chapter(1),
      "OEBPS/Text/ch2.xhtml" => kepub_chapter(2), "OEBPS/Text/ch3.xhtml" => kepub_chapter(3) })
    @asset_id = Consumer::LibraryAssets.new(@book).list.sole.id
    plain = @device.send_book!(@book)
    assert_equal [ "EPUB", "already_kobo_markup" ], plain.publication.values_at("format", "kepub_unavailable")
    plain.update!(last_download_at: Time.current)
    second = sync(@first.token)
    assert_equal "NewEntitlement", second.items.sole.keys.sole
    read_in_shelfarr
    assert_empty sync(second.token).items
    assert_equal %w[unsupported kepub_unavailable already_kobo_markup], plain.reload.progress_outbound.values_at("status", "reason", "kepub_reason")

    # A plain EPUB delivered before Kobo editions existed keeps its bytes.
    plain.update_columns(publication: plain.publication.except("kepub_unavailable"), progress_outbound: nil)
    Kobo::OutboundProgress.refresh(@device.reload, only: plain.reload)
    assert_equal %w[unsupported plain_epub], plain.reload.progress_outbound.values_at("status", "reason")

    private_copy = @device.kobo_deliveries.new(entitlement_id: SecureRandom.uuid, revision_id: SecureRandom.uuid, sync_revision: 1,
      publication: plain.publication, kobo_account_book_id: 1)
    assert_not Kobo::OutboundProgress.eligible?(private_copy)
    assert_equal [ nil, false ], Kobo::OutboundProgress.serve(private_copy, progress)
  end

  test "a changed, replaced, ambiguous or different edition never receives a mapped place" do
    read_in_shelfarr
    progress.update_columns(asset_id: "0" * 64)
    assert_empty sync(@first.token).items
    assert_equal %w[unsupported different_edition], @delivery.reload.progress_outbound.values_at("status", "reason")

    File.rename(@path, "#{@path}.old")
    prepare_kobo_kepub(chapters: { "OEBPS/Text/ch2.xhtml" => kepub_chapter(2, first: 30) })
    @asset_id = Consumer::LibraryAssets.new(@book).list.sole.id
    read_in_shelfarr(at: 1.hour.ago)
    assert_empty sync(@first.token).items
    assert_equal %w[unsupported file_changed], @delivery.reload.progress_outbound.values_at("status", "reason")

    replacement = @device.send_book!(@book)
    assert_nil replacement.progress_outbound, "a new file starts with no outbound place"
    third = sync(@first.token)
    assert_equal "NewEntitlement", third.items.sole.keys.sole
    assert_nil third.items.sole.dig("NewEntitlement", "ReadingState"), "not downloaded yet: nothing is sent"
    assert_equal %w[waiting not_downloaded], @delivery.reload.progress_outbound.values_at("status", "reason")

    replacement.update!(last_download_at: Time.current)
    assert_empty sync(third.token).items
    outbound = @delivery.reload.progress_outbound
    assert_equal %w[needs_choice edition_unverified kobo.32.2], outbound.values_at("status", "reason", "span")
    Kobo::OutboundProgress.new(@delivery, progress).choose!
    assert_equal "kobo.32.2", state_items(sync(third.token)).sole.dig("CurrentBookmark", "Location", "Value")
  end

  test "unsupported chapters preserve both places and explain why" do
    prepare_kobo_kepub(chapters: { "OEBPS/Text/ch2.xhtml" => "<html><body><p>No Kobo markers.</p></body></html>",
      "OEBPS/Text/ch3.xhtml" => %(<!DOCTYPE html [<!ENTITY x SYSTEM "file:///etc/passwd">]><html><body><span class="koboSpan" id="kobo.1.1">&x;</span></body></html>) })
    @asset_id = Consumer::LibraryAssets.new(@book).list.sole.id
    @device.send_book!(@book).update!(last_download_at: Time.current)
    cursor = sync(@first.token).token
    kobo_uploads(kobo_bookmark(span: "kobo.1.1", source: "OEBPS/Text/chapter 1.xhtml", at: 3.hours.ago))
    stored = @delivery.reload.reading_state

    { "OEBPS/Text/ch2.xhtml" => "no_kobo_spans", "OEBPS/Text/ch3.xhtml" => "unsafe_resource",
      "OEBPS/Text/missing.xhtml" => "location_not_in_edition", "OEBPS/cover.png" => "location_not_in_edition" }.each_with_index do |(href, reason), index|
      saved = read_in_shelfarr(href: href, at: (60 - index).minutes.ago)
      assert_empty sync(cursor).items, href
      assert_equal [ "unsupported", reason ], @delivery.reload.progress_outbound.values_at("status", "reason"), href
      assert_equal saved.attributes, progress.attributes
      assert_equal stored, @delivery.reading_state, "the Kobo's own place is kept"
    end
  end

  test "an oversized chapter in the delivered file is refused before it is read" do
    prepare_kobo_kepub(chapters: { "OEBPS/Text/ch2.xhtml" => kepub_chapter(2) + (" " * (Kobo::SpanIndex::MAX_BYTES + 1)) })
    @asset_id = Consumer::LibraryAssets.new(@book).list.sole.id
    @device.send_book!(@book).update!(last_download_at: Time.current)
    read_in_shelfarr
    sync(@first.token)
    assert_equal %w[unsupported chapter_too_large], @delivery.reload.progress_outbound.values_at("status", "reason")
  end

  test "a newer Shelfarr place saved during evaluation is not overwritten by the stale one" do
    stale = read_in_shelfarr(at: 2.hours.ago)
    read_in_shelfarr(href: "OEBPS/Text/ch3.xhtml", at: 1.hour.ago)
    revision = @device.reload.sync_revision
    Kobo::OutboundProgress.new(@delivery.reload, stale).evaluate!
    assert_equal revision, @device.reload.sync_revision, "a stale evaluation is not queued"
    state = state_items(sync(@first.token)).sole
    assert_equal "OEBPS/Text/ch3.xhtml", state.dig("CurrentBookmark", "Location", "Source")
  end

  test "a failure while mapping keeps syncing working and records no file details" do
    read_in_shelfarr
    Consumer::LibraryAssets.stub(:new, ->(*) { raise "private/library/path" }) do
      assert_empty sync(@first.token).items
    end
    assert_equal "unavailable", @delivery.reload.progress_outbound["status"]
    assert_not @delivery.progress_outbound.to_json.include?("private/library/path")
  end

  test "an explicit send is refused once Shelfarr's place has changed" do
    @device.update!(share_progress: false)
    kobo_uploads(kobo_bookmark(span: "kobo.1.1", source: "OEBPS/Text/ch3.xhtml", at: 1.minute.ago))
    old = read_in_shelfarr(at: 1.hour.ago)
    sync(@first.token)
    read_in_shelfarr(at: 30.minutes.ago)
    assert_raises(Kobo::OutboundProgress::NothingToSend) { Kobo::OutboundProgress.new(@delivery.reload, progress).choose! }
    assert_raises(Kobo::OutboundProgress::NothingToSend) { Kobo::OutboundProgress.new(@delivery.reload, old).choose! }
  end

  test "a newer percentage-only Kobo place and a Kobo place without a usable time are never overridden" do
    @device.update!(share_progress: false)
    kobo_uploads({ "LastModified" => 5.minutes.ago.utc.iso8601(7), "ProgressPercent" => 61 })
    read_in_shelfarr(at: 1.hour.ago)
    assert_empty sync(@first.token).items
    assert_equal %w[needs_choice kobo_newer], @delivery.reload.progress_outbound.values_at("status", "reason")

    @delivery.update_columns(reading_state: nil, progress_outbound: nil)
    Kobo::OutboundProgress.refresh(@device.reload)
    assert_equal "queued", @delivery.reload.progress_outbound["status"]
    kobo_uploads(kobo_bookmark(span: "kobo.2.2", source: "OEBPS/Text/ch3.xhtml", at: Time.current).merge("LastModified" => "yesterday"))
    assert_empty sync(@first.token).items, "a Kobo place that can't be compared keeps the Kobo's place"
  end

  test "two syncs queuing the same place at once advance the revision only once" do
    read_in_shelfarr
    stale_delivery = @device.kobo_deliveries.find(@delivery.id)
    revision = @device.reload.sync_revision
    Kobo::OutboundProgress.new(@delivery.reload, progress).evaluate!
    Kobo::OutboundProgress.new(stale_delivery, progress).evaluate!
    assert_equal revision + 1, @device.reload.sync_revision
    assert_equal 1, state_items(sync(@first.token)).size
  end
end
