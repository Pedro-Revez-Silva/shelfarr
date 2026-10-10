# frozen_string_literal: true

require "test_helper"

class Hardcover::SubscriptionSyncTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:enabled_languages, [ "en" ])
    @user = users(:one)
  end

  test "a Want to Read preview records every entry without requesting anything" do
    create_hardcover_connection(@user)
    subscription = create_hardcover_subscription(@user, kind: "want_to_read", status: "draft")
    subscription.update!(snapshot_state: "loading")
    first_page = 100.times.map { |index| hardcover_user_book_row(hardcover_book(id: 1_000 + index), id: 10_000 + index) }
    second_page = [
      hardcover_user_book_row(hardcover_book(id: 2_000), id: 20_000),
      hardcover_user_book_row(hardcover_book(id: 2_001, release_date: 2.months.from_now.to_date.iso8601), id: 20_001)
    ]
    stub_hardcover_graphql("ShelfarrWantToRead" => ->(variables) { { "user_books" => variables["offset"].zero? ? first_page : second_page } })

    assert_no_difference -> { Request.count } do
      Hardcover::SubscriptionSync.call(subscription, mode: :snapshot)
    end

    subscription.reload
    assert_equal "ready", subscription.snapshot_state
    assert_equal 102, subscription.items.count
    assert_equal 101, subscription.items.known.count
    assert_equal [ 2_001 ], subscription.items.upcoming.pluck(:hardcover_book_id)
    assert_equal 102, subscription.entries_seen_count
    assert_not subscription.entries_truncated
    assert_equal [ 0, 100 ], hardcover_requests.map { |request| request[:variables]["offset"] }
    assert_equal [ 4242 ], hardcover_requests.map { |request| request[:variables]["userId"] }.uniq
    assert hardcover_requests.all? { |request| request[:authorization] == "Bearer hc_at_test_#{@user.id}" }
    assert_nil subscription.baseline_established_at, "a preview never establishes a baseline by itself"
  end

  test "turning automatic requests off while Hardcover is being read leaves new entries for review" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", target_id: 77, automatic: true, book_types: %w[ebook audiobook])
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => ->(_variables) do
      HardcoverSubscription.find(subscription.id).update_settings!(book_types: [ "audiobook" ], automatic: false)
      { "list_books" => [ hardcover_list_book_row(hardcover_book(id: 31), id: 531, date_added: 1.hour.ago.iso8601) ] }
    end)

    result = Hardcover::SubscriptionSync.call(subscription)

    assert_equal 0, result.queued
    assert_equal [ "pending", [] ], [ subscription.items.sole.state, subscription.items.sole.book_types ]
    subscription.reload
    assert_equal [ false, [ "audiobook" ] ], [ subscription.automatic?, subscription.book_types ], "the sync keeps the new settings"
  end

  test "an automatic list sync queues only entries added after the baseline" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", target_id: 77, automatic: true, book_types: %w[ebook audiobook], baseline: 2.days.ago)
    create_hardcover_item(subscription, book_id: 3, state: "known")
    rows = [
      hardcover_list_book_row(hardcover_book(id: 1), id: 501, date_added: 1.day.ago.iso8601),
      hardcover_list_book_row(hardcover_book(id: 2), id: 502, date_added: 10.days.ago.iso8601, updated_at: 1.hour.ago.iso8601),
      hardcover_list_book_row(hardcover_book(id: 3, title: "Renamed"), id: 503, date_added: 20.days.ago.iso8601, updated_at: 1.hour.ago.iso8601)
    ]
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => { "list_books" => rows })

    result = Hardcover::SubscriptionSync.call(subscription)

    assert_equal 1, result.queued
    items = subscription.items.index_by(&:hardcover_book_id)
    assert_equal "queued", items[1].state
    assert_equal %w[ebook audiobook], items[1].book_types
    assert_not items[1].wanted?, "automatic additions are distinguished from explicit selections"
    assert_equal "known", items[2].state, "entries that existed before the baseline are never requested automatically"
    assert_equal "known", items[3].state
    assert_equal "Renamed", items[3].title
    since = Time.zone.parse(hardcover_requests.last[:variables]["since"])
    assert_in_delta subscription.reload.sync_cursor_at, Time.current, 5
    assert_in_delta 2.days.ago - 1.hour, since, 5
    assert_equal 0, Request.where(created_via: "hardcover").count, "the sync only queues; the import job creates requests"
  end

  test "new additions wait for review when automatic requests are off" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", automatic: false)
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => { "list_books" => [ hardcover_list_book_row(hardcover_book(id: 9), id: 1, date_added: 1.hour.ago.iso8601) ] })

    Hardcover::SubscriptionSync.call(subscription)

    assert_equal "pending", subscription.items.find_by!(hardcover_book_id: 9).state
  end

  test "an author sync separates new releases, backlist, upcoming books, and other contributors' work" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "author", target_id: 501, automatic: true, baseline: 10.days.ago)
    moved = create_hardcover_item(subscription, book_id: 40, state: "upcoming", release_date: 1.month.from_now.to_date)
    stub_hardcover_graphql("ShelfarrAuthorRecentContributions" => { "contributions" => [
      hardcover_contribution_row(hardcover_book(id: 10, release_date: 3.days.ago.to_date.iso8601), id: 1),
      hardcover_contribution_row(hardcover_book(id: 11, release_date: "2009-05-01"), id: 2),
      hardcover_contribution_row(hardcover_book(id: 12, release_date: 3.months.from_now.to_date.iso8601), id: 3),
      hardcover_contribution_row(hardcover_book(id: 13), id: 4, contribution: "Translator"),
      hardcover_contribution_row(hardcover_book(id: 14), id: 5, contribution: "Editor"),
      hardcover_contribution_row(hardcover_book(id: 40, release_date: 2.months.from_now.to_date.iso8601), id: 6)
    ] })

    Hardcover::SubscriptionSync.call(subscription)

    states = subscription.items.pluck(:hardcover_book_id, :state).to_h
    assert_equal "queued", states[10]
    assert_equal "known", states[11], "an old book added to Hardcover later is backlist, not a new release"
    assert_equal "upcoming", states[12]
    assert_nil states[13]
    assert_nil states[14]
    assert_equal 2.months.from_now.to_date, moved.reload.release_date
    assert_equal({ "role" => 2 }, subscription.reload.exclusions)
  end

  # Answers incremental list reads the way Hardcover's query does: rows
  # changed since `since`, below `beforeId`, newest row first.
  def list_changes(rows)
    ->(variables) do
      since = Time.zone.parse(variables["since"])
      matching = rows.select do |row|
        row["id"] < variables["beforeId"] &&
          [ row["date_added"], row["updated_at"] ].compact.any? { |time| Time.zone.parse(time) >= since }
      end
      { "list_books" => matching.sort_by { |row| -row["id"] }.first(variables["limit"]) }
    end
  end

  test "a window larger than one run is drained across runs exactly once" do
    configure_hardcover_instance_token
    freeze_time
    baseline = 2.days.ago
    subscription = create_hardcover_subscription(@user, kind: "list", automatic: true, baseline: baseline)
    # 600 books were added during downtime, all well before this check.
    rows = (1..600).map { |id| hardcover_list_book_row(hardcover_book(id: 10_000 + id), id: id, date_added: 2.hours.ago.iso8601) }
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => list_changes(rows))
    first_started = Time.current

    first = Hardcover::SubscriptionSync.call(subscription)

    assert_equal [ 500, 500, 500, true ], [ first.fetched, first.created, first.queued, first.continuing ]
    subscription.reload
    assert subscription.catching_up?, "an unfinished window is visible on the subscription"
    assert_equal baseline.to_i, subscription.sync_cursor_at.to_i, "the cursor waits until the whole window is read"
    assert_equal 101, subscription.sync_window_before_id
    assert_operator subscription.next_sync_at, :<=, Time.current
    assert_match(/Catching up/, ApplicationController.helpers.hardcover_sync_status(subscription))

    # Upstream keeps changing while Shelfarr catches up.
    travel 2.minutes
    rows << hardcover_list_book_row(hardcover_book(id: 20_000), id: 601, date_added: Time.current.iso8601)
    rows.find { |row| row["id"] == 50 }["updated_at"] = Time.current.iso8601

    second = Hardcover::SubscriptionSync.call(subscription)

    assert_equal [ 100, 100, false ], [ second.created, second.queued, second.continuing ]
    subscription.reload
    assert_not subscription.catching_up?
    assert_equal first_started.to_i, subscription.sync_cursor_at.to_i

    travel 6.hours
    third = Hardcover::SubscriptionSync.call(subscription)

    assert_equal [ 1, 1 ], [ third.created, third.queued ], "only the book added meanwhile is new"
    items = subscription.items
    assert_equal 601, items.count
    assert_equal 601, items.queued.count
    assert_equal (10_001..10_600).to_a + [ 20_000 ], items.order(:hardcover_book_id).pluck(:hardcover_book_id)
    assert items.none?(&:baseline?)
    assert_equal [ "ShelfarrPublicListBooksSince" ], hardcover_operations.uniq, "no snapshot of the whole list is ever taken"
    assert_equal 8, hardcover_requests.size
    assert_equal [ 2_147_483_647, 501, 401, 301, 201, 101, 1, 2_147_483_647 ], hardcover_requests.map { |request| request[:variables]["beforeId"] }
  end

  test "a failed page keeps what was read and the next run continues after it" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", automatic: true, baseline: 2.days.ago)
    cursor = subscription.sync_cursor_at
    rows = (1..300).map { |id| hardcover_list_book_row(hardcover_book(id: 100 + id), id: id, date_added: 1.hour.ago.iso8601) }
    reader = list_changes(rows)
    outage = true
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => ->(variables) do
      if outage && variables["beforeId"] <= 101
        [ 503, { error: "Service temporarily unavailable" } ]
      else
        reader.call(variables)
      end
    end)

    assert_raises(HardcoverClient::TransientError) { Hardcover::SubscriptionSync.call(subscription) }

    subscription.reload
    assert_equal 200, subscription.items.count, "pages read before the outage are kept"
    assert_equal cursor.to_i, subscription.sync_cursor_at.to_i
    assert_equal 101, subscription.sync_window_before_id

    outage = false
    hardcover_requests.clear
    result = Hardcover::SubscriptionSync.call(subscription)

    assert_equal 101, hardcover_requests.first[:variables]["beforeId"], "the next run resumes after the last saved page"
    assert_equal 100, result.created
    assert_equal 300, subscription.items.count
    assert_not subscription.reload.catching_up?
  end

  test "a full page without row ids stops the sync instead of skipping the rest of the window" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", automatic: true)
    cursor = subscription.sync_cursor_at
    rows = 100.times.map { |index| hardcover_list_book_row(hardcover_book(id: 100 + index), id: nil, date_added: 1.hour.ago.iso8601) }
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => { "list_books" => rows })

    assert_raises(HardcoverClient::Error) { Hardcover::SubscriptionSync.call(subscription) }

    assert_equal cursor.to_i, subscription.reload.sync_cursor_at.to_i
    assert_equal 0, subscription.items.count
  end

  test "an empty response is not treated as removals" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list")
    item = create_hardcover_item(subscription, book_id: 5, state: "requested")
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => { "list_books" => [] })

    Hardcover::SubscriptionSync.call(subscription)

    assert_equal "requested", item.reload.state
    assert_equal 1, subscription.items.count
  end

  test "a list followed by a connected user is read with their own token" do
    configure_hardcover_instance_token
    create_hardcover_connection(@user)
    subscription = create_hardcover_subscription(@user, kind: "list")
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => { "list_books" => [] })

    Hardcover::SubscriptionSync.call(subscription)

    assert_equal "Bearer hc_at_test_#{@user.id}", hardcover_requests.last[:authorization]
  end

  test "a very long list preview is bounded and flagged" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", status: "draft")
    stub_hardcover_graphql("ShelfarrPublicListBooks" => ->(variables) do
      offset = variables["offset"]
      { "list_books" => 100.times.map { |index| hardcover_list_book_row(hardcover_book(id: offset + index + 1), id: offset + index + 1) } }
    end)

    Hardcover::SubscriptionSync.call(subscription, mode: :snapshot)

    assert_equal Hardcover::SubscriptionSync::MAX_SNAPSHOT_PAGES, hardcover_requests.size
    assert subscription.reload.entries_truncated
    assert_equal 1_000, subscription.items.count
  end

  # Recent-first author reads, ordered like Hardcover's query: release date
  # descending (no date last), then contribution id descending.
  def author_provider(contributions)
    recent = ->(variables) do
      ordered = contributions.sort_by do |row|
        date = row.dig("book", "release_date")
        [ date ? 0 : 1, date ? -Date.iso8601(date).jd : 0, -row["id"] ]
      end
      { "contributions" => ordered.drop(variables["offset"]).first(variables["limit"]) }
    end
    catalog = ->(variables) do
      { "contributions" => contributions.select { |row| row["id"] > variables["afterId"] }.sort_by { |row| row["id"] }.first(variables["limit"]) }
    end
    { "ShelfarrAuthorRecentContributions" => recent, "ShelfarrAuthorCatalogContributions" => catalog }
  end

  test "a long author catalog always sees new releases and covers older books over later checks" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "author", target_id: 501, automatic: true, baseline: 10.days.ago)
    # 1,050 records; every seventh credits the author only as editor. The
    # newest release is the most recently created record, the one an
    # oldest-first scan capped at 1,000 records would never reach.
    contributions = (1..1_050).map do |id|
      release = id == 1_050 ? 2.days.ago.to_date : Date.new(1950, 1, 1) + id
      hardcover_contribution_row(hardcover_book(id: 50_000 + id, title: "Book #{id}", release_date: release.iso8601), id: id,
        contribution: id % 7 == 1 ? "Editor" : nil)
    end
    stub_hardcover_graphql(author_provider(contributions))

    first = Hardcover::SubscriptionSync.call(subscription)

    latest = subscription.items.find_by!(hardcover_book_id: 51_050)
    assert_equal "queued", latest.state, "the newest release is found on the first check"
    assert_equal 1, first.queued
    assert first.truncated
    subscription.reload
    assert subscription.entries_truncated
    assert_equal 200, subscription.catalog_cursor_id

    authored = contributions.reject { |row| row["contribution"] == "Editor" }.map { |row| row.dig("book", "id") }
    5.times { Hardcover::SubscriptionSync.call(subscription.reload) }

    assert_equal 0, subscription.reload.catalog_cursor_id, "the walk starts over after reaching the end"
    assert_equal authored.sort, subscription.items.order(:hardcover_book_id).pluck(:hardcover_book_id), "every written book is tracked; editor credits are not"
    assert_equal 1, subscription.items.queued.count, "older books are backlist, never requested automatically"

    # A later release is picked up by the very next check.
    contributions << hardcover_contribution_row(hardcover_book(id: 60_000, title: "Brand New", release_date: Date.current.iso8601), id: 1_051)
    contributions << hardcover_contribution_row(hardcover_book(id: 60_001, title: "Announced", release_date: 2.months.from_now.to_date.iso8601), id: 1_052)
    Hardcover::SubscriptionSync.call(subscription.reload)

    assert_equal "queued", subscription.items.find_by!(hardcover_book_id: 60_000).state
    assert_equal "upcoming", subscription.items.find_by!(hardcover_book_id: 60_001).state
    assert_equal({ "role" => 142 }, subscription.reload.exclusions)
  end

  test "an author preview reads only the recent scan" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "author", target_id: 501, status: "draft")
    contributions = (1..1_050).map { |id| hardcover_contribution_row(hardcover_book(id: 50_000 + id, title: "Book #{id}"), id: id) }
    stub_hardcover_graphql(author_provider(contributions))

    Hardcover::SubscriptionSync.call(subscription, mode: :snapshot)

    assert_equal [ "ShelfarrAuthorRecentContributions" ], hardcover_operations.uniq
    assert_equal Hardcover::SubscriptionSync::MAX_SNAPSHOT_PAGES, hardcover_requests.size
    assert subscription.items.all?(&:baseline?)
  end

  test "Want to Read is only read with the account it was previewed with" do
    create_hardcover_connection(@user, hardcover_user_id: 5_555)
    subscription = create_hardcover_subscription(@user, kind: "want_to_read", account_id: 4_242)

    assert_raises(Hardcover::Credentials::AccountMismatch) { Hardcover::SubscriptionSync.call(subscription) }

    assert_not_requested :post, HardcoverClient::BASE_URL
    assert_equal 0, subscription.items.count
  end

  test "a private list falls back to nobody else's credentials" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", account_id: 4_242, personal: true)

    assert_raises(Hardcover::Credentials::Unavailable) { Hardcover::SubscriptionSync.call(subscription) }
    assert_not_requested :post, HardcoverClient::BASE_URL
  end

  # Answers the author's recent scan from `books`, which a test can change
  # between syncs the way Hardcover's records change over time.
  def author_books(books)
    ->(_variables) { { "contributions" => books.each_with_index.map { |book, index| hardcover_contribution_row(book.call, id: index + 1) } } }
  end

  test "an undated book first seen after the baseline is requested once Hardcover dates it as a new release" do
    configure_hardcover_instance_token
    SettingsService.set(:immediate_search_enabled, false)
    subscription = create_hardcover_subscription(@user, kind: "author", target_id: 501, automatic: true, baseline: 10.days.ago)
    previewed = create_hardcover_item(subscription, book_id: 72, state: "known", baseline: true)
    dates = { 70 => nil, 71 => nil, 72 => nil }
    stub_hardcover_graphql("ShelfarrAuthorRecentContributions" => author_books(
      dates.keys.map { |id| -> { hardcover_book(id: id, release_date: dates[id]) } }
    ))

    Hardcover::SubscriptionSync.call(subscription)

    fresh = subscription.items.find_by!(hardcover_book_id: 70)
    backlist = subscription.items.find_by!(hardcover_book_id: 71)
    assert_equal [ "known", false ], [ fresh.state, fresh.baseline? ], "an undated book seen after the baseline is not part of it"
    assert_equal [ "known", false ], [ backlist.state, backlist.baseline? ]

    # Hardcover fills in the dates: one new release, one old book, and a
    # date for the book that was already there when the author was previewed.
    dates.merge!(70 => Date.current.iso8601, 71 => "2001-03-04", 72 => Date.current.iso8601)
    result = Hardcover::SubscriptionSync.call(subscription.reload)

    assert_equal 1, result.queued
    assert_equal [ "queued", [ "ebook" ] ], [ fresh.reload.state, fresh.book_types ]
    assert_equal "known", backlist.reload.state, "a book dated long ago is backlist"
    assert_equal "known", previewed.reload.state, "a book left unselected in the preview stays unrequested"

    assert_difference -> { Request.count } => 1 do
      HardcoverSyncSchedulerJob.perform_now
      Hardcover::ItemImporter.call
    end
    request = Request.where(id: fresh.reload.request_ids).sole
    assert_equal [ "requested", @user, "hardcover", "70" ], [ fresh.state, request.user, request.created_via, request.book.hardcover_id ]

    assert_no_difference -> { Request.count } do
      Hardcover::SubscriptionSync.call(subscription.reload)
      HardcoverSyncSchedulerJob.perform_now
      Hardcover::ItemImporter.call
    end
  end

  test "a release postponed after it was queued waits for its new date and is then requested once" do
    configure_hardcover_instance_token
    SettingsService.set(:immediate_search_enabled, false)
    subscription = create_hardcover_subscription(@user, kind: "author", target_id: 501, automatic: true, baseline: 10.days.ago)
    original = Date.yesterday
    dates = { 80 => original, 81 => original, 82 => original }
    stub_hardcover_graphql("ShelfarrAuthorRecentContributions" => author_books(
      dates.keys.map { |id| -> { hardcover_book(id: id, release_date: dates[id].iso8601) } }
    ))
    travel_to(2.days.ago) { Hardcover::SubscriptionSync.call(subscription) }
    announced = subscription.items.find_by!(hardcover_book_id: 80)
    assert_equal "upcoming", announced.state
    selected = subscription.items.find_by!(hardcover_book_id: 81)
    selected.update!(wanted: true, book_types: [ "audiobook" ])
    requested = subscription.items.find_by!(hardcover_book_id: 82)

    HardcoverSyncSchedulerJob.perform_now
    assert_equal [ "queued", "queued" ], [ announced.reload.state, selected.reload.state ]
    requested.update!(state: "requested", request_ids: [ 4_242 ])

    # The publisher moves the release two weeks out before the import runs.
    postponed = 2.weeks.from_now.to_date
    dates.transform_values! { postponed }
    Hardcover::SubscriptionSync.call(subscription.reload)

    announced.reload
    assert_equal [ "upcoming", postponed, false, [ "ebook" ], nil ], [ announced.state, announced.release_date, announced.wanted?, announced.book_types, announced.claim_token ]
    assert_equal [ "upcoming", true, [ "audiobook" ] ], [ selected.reload.state, selected.wanted?, selected.book_types ], "the selection and formats wait with it"
    assert_equal [ "requested", [ 4_242 ] ], [ requested.reload.state, requested.request_ids ], "requests already made are kept"
    assert_no_difference -> { Request.count } do
      HardcoverSyncSchedulerJob.perform_now
      assert_equal 0, Hardcover::ItemImporter.call.processed
    end

    travel_to(postponed.in_time_zone + 1.hour) do
      assert_difference -> { Request.count } => 2 do
        HardcoverSyncSchedulerJob.perform_now
        Hardcover::ItemImporter.call
      end
      assert_equal [ "requested", "requested" ], [ announced.reload.state, selected.reload.state ]
      assert_equal [ "audiobook" ], Request.where(id: selected.request_ids).map { |request| request.book.book_type }

      assert_no_difference -> { Request.count } do
        Hardcover::SubscriptionSync.call(subscription.reload)
        HardcoverSyncSchedulerJob.perform_now
        Hardcover::ItemImporter.call
      end
    end
  end

  test "a sync that started before the account changed discards what it read" do
    create_hardcover_connection(@user)
    subscription = create_hardcover_subscription(@user, kind: "want_to_read", automatic: true)
    stub_hardcover_graphql("ShelfarrWantToReadSince" => ->(_variables) do
      HardcoverSubscription.find(subscription.id).restart_preview_for!(account_id: 5_555, username: "other")
      { "user_books" => [ hardcover_user_book_row(hardcover_book(id: 7), id: 1, created_at: 1.minute.ago.iso8601) ] }
    end)

    assert_raises(Hardcover::SubscriptionSync::Stale) { Hardcover::SubscriptionSync.call(subscription) }

    subscription.reload
    assert subscription.draft?
    assert_equal 5_555, subscription.hardcover_account_id
    assert_equal 0, subscription.items.count
  end
end
