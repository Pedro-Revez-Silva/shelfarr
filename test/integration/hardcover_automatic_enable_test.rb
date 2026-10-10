# frozen_string_literal: true

require "test_helper"

class HardcoverAutomaticEnableTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    configure_hardcover_instance_token
    SettingsService.set(:immediate_search_enabled, false)
  end

  %w[list want_to_read].each do |kind|
    [ true, false ].each do |observed_before|
      test "#{kind} automatic enable keeps older additions for review when first observed #{observed_before ? 'before' : 'after'} enabling" do
        freeze_time do
          create_hardcover_connection(@user) if kind == "want_to_read"
          subscription = create_hardcover_subscription(@user, kind: kind, automatic: false)
          older = 1.day.ago
          future = 3.days.from_now.to_date
          rows = [ entry_row(kind, 901, older), entry_row(kind, 902, older, release_date: future.iso8601) ]
          stub_entries(kind, rows)
          if observed_before
            HardcoverSubscriptionSyncJob.perform_now(subscription.id)
            assert_equal %w[pending upcoming], subscription.items.order(:hardcover_book_id).pluck(:state)
          end

          enable(subscription)
          assert_equal Time.current, subscription.reload.automatic_enabled_at
          travel 1.hour
          if observed_before && kind == "want_to_read"
            # An edit to an existing shelf row changes updated_at. It does
            # not make an already observed addition a new opt-in request.
            rows.each { |row| row["updated_at"] = Time.current.iso8601 }
          end
          rows.concat([
            entry_row(kind, 903, Time.current),
            entry_row(kind, 904, Time.current, release_date: future.iso8601),
            entry_row(kind, 905, nil),
            entry_row(kind, 906, nil, release_date: future.iso8601)
          ])
          HardcoverSubscriptionSyncJob.perform_now(subscription.id)
          assert_equal %w[pending upcoming queued upcoming pending upcoming], subscription.items.order(:hardcover_book_id).pluck(:state)
          HardcoverImportJob.perform_now
          assert_equal [ "903" ], requested_ids
          assert_equal %w[pending upcoming requested upcoming pending upcoming], subscription.items.order(:hardcover_book_id).pluck(:state)

          travel 4.days
          HardcoverSyncSchedulerJob.perform_now
          assert_equal %w[pending pending requested queued pending pending], subscription.items.order(:hardcover_book_id).pluck(:state)
          HardcoverImportJob.perform_now
          assert_equal %w[903 904], requested_ids, "only additions made after enabling may request on release"
          assert_equal %w[pending pending requested requested pending pending], subscription.items.order(:hardcover_book_id).pluck(:state)

          older_item = subscription.items.find_by!(hardcover_book_id: 902)
          post request_items_hardcover_subscription_path(subscription), params: { book_types: [ "ebook" ], item_ids: [ older_item.id ] }
          assert_redirected_to hardcover_subscription_path(subscription, filter: "requested")
          HardcoverImportJob.perform_now
          assert_equal %w[902 903 904], requested_ids, "an explicit selection still requests an older addition"
          assert older_item.reload.wanted?
        end
      end
    end
  end

  test "initial confirmation starts automation at confirmation rather than the earlier preview" do
    freeze_time do
      subscription = create_hardcover_subscription(@user, status: "draft")
      patch hardcover_subscription_path(subscription), params: { automatic: "1", book_types: [ "ebook" ] }
      assert_equal Time.current, subscription.reload.automatic_enabled_at
      rows = [ entry_row("list", 901, 1.day.ago), entry_row("list", 902, Time.current) ]
      stub_entries("list", rows)

      HardcoverSubscriptionSyncJob.perform_now(subscription.id)
      HardcoverImportJob.perform_now

      assert_equal [ "902" ], requested_ids
      assert_equal "pending", subscription.items.find_by!(hardcover_book_id: 901).state
    end
  end

  test "an in-flight sync uses the enable boundary saved while Hardcover was being read" do
    freeze_time do
      subscription = create_hardcover_subscription(@user, automatic: false)
      enabled_at = nil
      stub_hardcover_graphql("ShelfarrPublicListBooksSince" => ->(_variables) do
        travel 1.minute
        enabled_at = Time.current
        HardcoverSubscription.find(subscription.id).update_settings!(book_types: [ "ebook" ], automatic: true)
        { "list_books" => [ entry_row("list", 901, 1.hour.ago), entry_row("list", 902, Time.current) ] }
      end)

      HardcoverSubscriptionSyncJob.perform_now(subscription.id)
      assert_equal %w[pending queued], subscription.items.order(:hardcover_book_id).pluck(:state)
      HardcoverImportJob.perform_now

      assert_equal [ "902" ], requested_ids
      assert_equal enabled_at, subscription.reload.automatic_enabled_at
      assert subscription.automatic?
    end
  end

  test "saving formats does not reset the boundary but turning off and on does" do
    freeze_time do
      subscription = create_hardcover_subscription(@user, automatic: false)
      enable(subscription)
      enabled_at = subscription.reload.automatic_enabled_at
      travel 1.hour
      rows = [ entry_row("list", 901, Time.current, release_date: Date.tomorrow.iso8601) ]
      stub_entries("list", rows)
      HardcoverSubscriptionSyncJob.perform_now(subscription.id)
      travel 1.hour
      patch hardcover_subscription_path(subscription), params: { automatic: "1", book_types: %w[ebook audiobook] }
      assert_equal enabled_at, subscription.reload.automatic_enabled_at
      patch hardcover_subscription_path(subscription), params: { automatic: "0", book_types: [ "ebook" ] }
      assert_nil subscription.reload.automatic_enabled_at
      travel 1.hour
      enable(subscription)
      assert_equal Time.current, subscription.reload.automatic_enabled_at

      travel 2.days
      HardcoverSyncSchedulerJob.perform_now
      HardcoverImportJob.perform_now
      assert_empty requested_ids, "an addition from the previous enabled period is left for review"
      assert_equal "pending", subscription.items.sole.state
    end
  end

  test "the importer checks the current boundary for automatic work queued earlier" do
    freeze_time do
      subscription = create_hardcover_subscription(@user, automatic: false)
      item = create_hardcover_item(subscription, book_id: 901, state: "queued", entry_added_at: 1.hour.ago, book_types: [ "ebook" ])
      enable(subscription)

      HardcoverImportJob.perform_now

      assert_empty requested_ids
      assert_equal "pending", item.reload.state
      item.queue_for_import!([ "ebook" ])
      HardcoverImportJob.perform_now
      assert_equal [ "901" ], requested_ids
    end
  end

  test "enabling an author still watches its previously announced future releases" do
    subscription = create_hardcover_subscription(@user, kind: "author", automatic: false)
    item = create_hardcover_item(subscription, book_id: 901, state: "upcoming", baseline: true, entry_added_at: nil, release_date: Date.yesterday)
    enable(subscription)

    HardcoverSyncSchedulerJob.perform_now
    HardcoverImportJob.perform_now

    assert_equal [ "901" ], requested_ids
    assert_equal "requested", item.reload.state
  end

  private

  def enable(subscription)
    patch hardcover_subscription_path(subscription), params: { automatic: "1", book_types: [ "ebook" ] }
    assert_redirected_to hardcover_subscription_path(subscription)
  end

  def entry_row(kind, id, added_at, release_date: "2021-04-06")
    book = hardcover_book(id: id, release_date: release_date)
    timestamp = added_at&.iso8601
    if kind == "want_to_read"
      hardcover_user_book_row(book, id: id, created_at: timestamp, updated_at: timestamp)
    else
      hardcover_list_book_row(book, id: id, date_added: timestamp)
    end
  end

  def stub_entries(kind, rows)
    operation, field = kind == "want_to_read" ? [ "ShelfarrWantToReadSince", "user_books" ] : [ "ShelfarrPublicListBooksSince", "list_books" ]
    stub_hardcover_graphql(operation => ->(_variables) { { field => rows } })
  end

  def requested_ids
    Request.joins(:book).where(created_via: "hardcover").order("books.hardcover_id").pluck("books.hardcover_id")
  end
end
