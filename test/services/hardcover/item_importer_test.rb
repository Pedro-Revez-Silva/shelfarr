# frozen_string_literal: true

require "test_helper"

class Hardcover::ItemImporterTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:immediate_search_enabled, false)
    @user = users(:one)
    @subscription = create_hardcover_subscription(@user, kind: "list", book_types: %w[ebook audiobook])
  end

  def queued_item(book_id, wanted: true, book_types: %w[ebook audiobook], **attrs)
    create_hardcover_item(@subscription, book_id: book_id, state: "queued", wanted: wanted, book_types: book_types,
      title: "Queued #{book_id}", release_year: 2020, cover_url: "https://assets.hardcover.app/#{book_id}.jpg", **attrs)
  end

  test "creates one normal request per selected format without another metadata lookup" do
    item = queued_item(9_001)

    assert_difference -> { Request.count } => 2, -> { Book.count } => 2 do
      Hardcover::ItemImporter.call
    end

    requests = Request.where(id: item.reload.request_ids).includes(:book)
    assert_equal %w[audiobook ebook], requests.map { |request| request.book.book_type }.sort
    assert requests.all? { |request| request.user == @user && request.pending? && request.created_via == "hardcover" && request.external_source == "hardcover" }
    assert requests.all? { |request| request.book.hardcover_id == "9001" && request.book.title == "Queued 9001" }
    assert_equal "requested", item.state
    assert_nil item.claim_token
    assert_match(/Requested ebook and audiobook|Requested audiobook and ebook/, item.resolution)
    assert_not_requested :post, HardcoverClient::BASE_URL
  end

  test "formats already in the library or already requested count as done" do
    owned = Book.create!(title: "Owned", hardcover_id: "9002", book_type: :ebook, file_path: "/ebooks/owned.epub")
    item = queued_item(9_002)

    assert_difference -> { Request.count } => 1 do
      Hardcover::ItemImporter.call
    end

    item.reload
    assert_equal "requested", item.state
    assert_includes item.resolution, "ebook already in Shelfarr"
    assert_equal 1, Book.where(hardcover_id: "9002", book_type: :ebook).count
    assert owned.reload.requests.none?

    other_subscription = create_hardcover_subscription(users(:two), kind: "author", target_id: 5)
    other_item = create_hardcover_item(other_subscription, book_id: 9_002, state: "queued", wanted: true, book_types: [ "audiobook" ])
    assert_no_difference -> { Request.count } do
      Hardcover::ItemImporter.call
    end
    assert_equal "requested", other_item.reload.state, "another user's open request covers the format"
  end

  test "a stale claim from a crashed run is reclaimed without duplicating requests" do
    item = queued_item(9_003, book_types: [ "ebook" ])
    Hardcover::ItemImporter.call
    request_id = item.reload.request_ids.first

    # Simulate a crash after requests were created but before the item was marked.
    item.update!(state: "queued", claim_token: "dead", claimed_at: 1.hour.ago, request_ids: [])

    assert_no_difference -> { Request.count } do
      Hardcover::ItemImporter.call
    end
    assert_equal "requested", item.reload.state
    assert_equal [ request_id ], item.request_ids
  end

  test "an item claimed by a running import is not processed twice" do
    item = queued_item(9_004, book_types: [ "ebook" ])
    item.update!(claim_token: "busy", claimed_at: 1.minute.ago)

    assert_no_difference -> { Request.count } do
      result = Hardcover::ItemImporter.call
      assert_equal 0, result.processed
    end
    assert_equal "busy", item.reload.claim_token
  end

  test "a failed creation is recorded for retry instead of being dropped" do
    item = queued_item(9_005, book_types: [ "ebook" ])
    failure = RequestCreationService::Result.new(created_requests: [], warnings: [], errors: [ "Book could not be saved" ])

    RequestCreationService.stub(:call, failure) do
      Hardcover::ItemImporter.call
    end

    item.reload
    assert_equal "failed", item.state
    assert_equal 1, item.attempts
    assert_equal "Book could not be saved", item.last_error
    assert_in_delta 10.minutes.from_now, item.next_attempt_at, 5
    assert_nil item.claim_token
  end

  test "automatic additions are capped per user and the overflow stays queued" do
    SettingsService.set(:hardcover_max_requests_per_run, 2)
    items = 3.times.map { |index| queued_item(9_100 + index, wanted: false, book_types: [ "ebook" ]) }

    result = Hardcover::ItemImporter.call

    assert_equal 2, result.requested
    assert_equal 1, result.deferred
    overflow = items.map(&:reload).find(&:queued?)
    assert overflow
    assert_operator overflow.next_attempt_at, :>, 10.minutes.from_now
    assert_equal 0, result.remaining, "deferred items wait for a later run"
  end

  test "explicit selections are not limited by the automatic cap" do
    SettingsService.set(:hardcover_max_requests_per_run, 1)
    3.times { |index| queued_item(9_200 + index, book_types: [ "ebook" ]) }

    assert_equal 3, Hardcover::ItemImporter.call.requested
  end

  test "paused subscriptions, deleted users, and a disabled provider stop imports" do
    item = queued_item(9_300, book_types: [ "ebook" ])

    @subscription.pause!("Paused by you.")
    assert_equal 0, Hardcover::ItemImporter.call.processed

    @subscription.resume!
    @user.update_column(:deleted_at, Time.current)
    assert_equal 0, Hardcover::ItemImporter.call.processed

    @user.update_column(:deleted_at, nil)
    SettingsService.set(:hardcover_enabled, false)
    assert_equal 0, Hardcover::ItemImporter.call.processed
    assert_equal "queued", item.reload.state
  end

  test "processes a large selection in bounded batches" do
    30.times { |index| queued_item(9_400 + index, book_types: [ "ebook" ]) }

    first = Hardcover::ItemImporter.call
    assert_equal Hardcover::ItemImporter::BATCH_SIZE, first.processed
    assert_equal 5, first.remaining

    assert_equal 5, Hardcover::ItemImporter.call.processed
  end

  # Runs the importer and applies `change` while the first item's requests
  # are being created, the way a web request can while a batch is running.
  def import_while(first_work_id)
    original = RequestCreationService.method(:call)
    changed = false
    creator = lambda do |**args|
      result = original.call(**args)
      if args[:work_id] == first_work_id && !changed
        changed = true
        yield
      end
      result
    end
    RequestCreationService.stub(:call, creator) { Hardcover::ItemImporter.call }
  end

  {
    "pausing the subscription" => ->(test) { HardcoverSubscription.find(test.subscription_id).pause!("Paused by you.") },
    "deleting the user" => ->(test) { User.find(test.user_id).soft_delete! },
    "disabling Hardcover" => ->(_test) { SettingsService.set(:hardcover_enabled, false) }
  }.each do |label, change|
    test "#{label} after a batch was claimed stops its remaining items" do
      first = queued_item(9_500, wanted: false, book_types: [ "ebook" ])
      second = queued_item(9_501, wanted: false, book_types: [ "ebook" ])
      third = queued_item(9_502, book_types: [ "ebook" ])

      result = nil
      assert_difference -> { Request.count } => 1 do
        result = import_while(third.work_id) { change.call(self) }
      end

      assert_equal 3, result.processed
      assert_equal 1, result.requested, "the request created before the change is kept"
      assert_equal 2, result.cancelled
      assert_equal "requested", third.reload.state
      [ first, second ].each do |item|
        item.reload
        assert_equal "queued", item.state, "an unprocessed item keeps its place"
        assert_nil item.claim_token, "and is released for a later run"
        assert_equal 0, item.attempts
      end
    end
  end

  test "disconnecting Want to Read during a batch stops it until a deliberate resume" do
    connection = create_hardcover_connection(@user, auth_method: "personal_token", access_token: "hc_pat")
    shelf = create_hardcover_subscription(@user, kind: "want_to_read", automatic: true)
    first = create_hardcover_item(shelf, book_id: 9_600, state: "queued", wanted: false, book_types: [ "ebook" ])
    second = create_hardcover_item(shelf, book_id: 9_601, state: "queued", wanted: false, book_types: [ "ebook" ])

    assert_difference -> { Request.count } => 1 do
      import_while(first.work_id) { Hardcover::ConnectionManager.disconnect!(connection) }
    end

    assert_equal "requested", first.reload.state
    assert_equal [ "queued", nil ], [ second.reload.state, second.claim_token ]
    assert shelf.reload.paused?
    assert_no_difference -> { Request.count } do
      assert_equal 0, Hardcover::ItemImporter.call.processed, "nothing runs while the shelf is paused"
    end

    create_hardcover_connection(@user, auth_method: "personal_token", access_token: "hc_pat_again")
    shelf.resume!
    assert_difference -> { Request.count } => 1 do
      Hardcover::ItemImporter.call
    end
    assert_equal "requested", second.reload.state
  end

  test "a personal subscription stops importing when another account is connected" do
    create_hardcover_connection(@user, hardcover_user_id: 5_555)
    shelf = create_hardcover_subscription(@user, kind: "want_to_read", account_id: 4_242, automatic: true)
    item = create_hardcover_item(shelf, book_id: 9_700, state: "queued", wanted: false, book_types: [ "ebook" ])

    assert_no_difference -> { Request.count } do
      result = Hardcover::ItemImporter.call
      assert_equal 1, result.cancelled
      assert_equal 0, result.remaining, "the rest of the queue waits instead of being claimed again"
    end
    assert_equal [ "queued", nil ], [ item.reload.state, item.claim_token ]
    assert_equal HardcoverSubscription::PAUSE_OTHER_ACCOUNT, shelf.reload.pause_reason
  end

  def subscription_id = @subscription.id
  def user_id = @user.id
end
