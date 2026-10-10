# frozen_string_literal: true

require "test_helper"

class Hardcover::ConnectionManagerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  TOKEN_URL = "https://api.hardcover.app/oauth2/token"
  REVOKE_URL = "https://api.hardcover.app/oauth2/revoke"

  setup do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_oauth_client_id, "client-123")
    SettingsService.set(:hardcover_oauth_client_secret, "")
    SettingsService.set(:immediate_search_enabled, false)
    stub_request(:get, Hardcover::Oauth::DISCOVERY_URL).to_return(status: 404)
    @revocations = []
    stub_request(:post, REVOKE_URL).to_return do |request|
      @revocations << Rack::Utils.parse_query(request.body)["token"]
      { status: 200, body: "{}" }
    end
    @user = users(:one)
  end

  # `me` answers with the account that owns each access token.
  def stub_accounts(accounts)
    stub_request(:post, HardcoverClient::BASE_URL).to_return do |request|
      token = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
      id, username = accounts.fetch(token)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: { data: { me: [ { id: id, username: username } ] } }.to_json }
    end
  end

  # Holds the token endpoint open until the test releases it, so a refresh
  # can be caught after it read the connection and before it saves.
  def pause_refresh(refresh_token, response)
    reached = Queue.new
    release = Queue.new
    stub_request(:post, TOKEN_URL).with(body: hash_including("refresh_token" => refresh_token)).to_return do |_request|
      reached << true
      release.pop
      { status: 200, body: response.to_json }
    end
    [ reached, release ]
  end

  def refresh_in_thread(connection)
    Thread.new do
      Hardcover::Oauth.refresh_connection!(HardcoverConnection.find(connection.id), force: true)
      :refreshed
    rescue Hardcover::Oauth::Error => e
      e
    end
  end

  test "a refresh that finishes after the account was replaced is discarded and revoked" do
    connection = create_hardcover_connection(@user, hardcover_user_id: 1_001, access_token: "old_access", refresh_token: "old_refresh", username: "old")
    reached, release = pause_refresh("old_refresh", access_token: "old_rotated_access", refresh_token: "old_rotated_refresh", expires_in: 604_800)
    stub_accounts("new_access" => [ 2_002, "new" ])

    worker = refresh_in_thread(connection)
    Timeout.timeout(10) { reached.pop }
    Hardcover::ConnectionManager.connect!(user: @user, auth_method: "oauth", access_token: "new_access", refresh_token: "new_refresh", expires_at: 1.week.from_now)
    release << true
    outcome = Timeout.timeout(10) { worker.value }

    assert_kind_of Hardcover::Oauth::ConnectionChanged, outcome
    saved = connection.reload
    assert_equal [ 2_002, "new", "new_access", "new_refresh" ], [ saved.hardcover_user_id, saved.hardcover_username, saved.access_token, saved.refresh_token ],
      "the replacement account keeps its own identity and tokens"
    assert_includes @revocations, "old_rotated_refresh", "tokens rotated for the replaced account are revoked, not stored"
    assert_includes @revocations, "old_refresh"
  end

  test "a refresh that finishes after disconnect cannot bring the connection back" do
    connection = create_hardcover_connection(@user, hardcover_user_id: 1_001, access_token: "old_access", refresh_token: "old_refresh")
    reached, release = pause_refresh("old_refresh", access_token: "rotated_access", refresh_token: "rotated_refresh", expires_in: 604_800)

    worker = refresh_in_thread(connection)
    Timeout.timeout(10) { reached.pop }
    Hardcover::ConnectionManager.disconnect!(connection)
    release << true
    outcome = Timeout.timeout(10) { worker.value }

    assert_kind_of Hardcover::Oauth::ConnectionChanged, outcome
    assert_not HardcoverConnection.exists?(user_id: @user.id)
    assert_includes @revocations, "rotated_refresh"
  end

  test "a refresh that loses the race is reported to callers as an unavailable connection" do
    connection = create_hardcover_connection(@user, hardcover_user_id: 1_001, access_token: "old_access", refresh_token: "old_refresh", expires_at: 1.minute.from_now)
    stub_request(:post, TOKEN_URL).to_return do |_request|
      HardcoverConnection.where(id: connection.id).delete_all
      { status: 200, body: { access_token: "late_access", refresh_token: "late_refresh", expires_in: 604_800 }.to_json }
    end

    assert_raises(Hardcover::Credentials::Unavailable) do
      Hardcover::Credentials.with_connection(connection) { flunk "nothing is read with a removed connection" }
    end
    assert_includes @revocations, "late_refresh"
  end

  test "connecting a different account starts a fresh Want to Read preview and never imports the new backlog" do
    create_hardcover_connection(@user, hardcover_user_id: 1_001, auth_method: "personal_token", access_token: "old_pat")
    shelf = create_hardcover_subscription(@user, kind: "want_to_read", account_id: 1_001, automatic: true, book_types: [ "ebook" ])
    create_hardcover_item(shelf, book_id: 1, state: "known", baseline: true)
    create_hardcover_item(shelf, book_id: 2, state: "requested", request_ids: [ 99 ])
    stale_copy = HardcoverSubscription.find(shelf.id)
    stub_accounts("new_pat" => [ 1_002, "second" ])

    assert_enqueued_with(job: HardcoverSubscriptionSyncJob, args: [ shelf.id, { mode: "snapshot" } ]) do
      Hardcover::ConnectionManager.connect!(user: @user, auth_method: "personal_token", access_token: "new_pat")
    end

    shelf.reload
    assert shelf.draft?, "a different account's shelf must be previewed again"
    assert_equal [ 1_002, "second", false ], [ shelf.hardcover_account_id, shelf.owner_username, shelf.automatic? ]
    assert_nil shelf.baseline_established_at
    assert_equal 0, shelf.items.count, "nothing from the previous account carries over"

    # A sync that was already running for the old account reads nothing.
    assert_raises(Hardcover::SubscriptionSync::Stale, Hardcover::Credentials::AccountMismatch) { Hardcover::SubscriptionSync.call(stale_copy) }
    assert_equal 0, shelf.items.count

    # The new account's existing shelf only becomes a preview.
    stub_hardcover_graphql("ShelfarrWantToRead" => ->(variables) do
      assert_equal 1_002, variables["userId"]
      { "user_books" => [ hardcover_user_book_row(hardcover_book(id: 40_000), id: 1, created_at: 1.day.ago.iso8601) ] }
    end)
    assert_no_difference -> { Request.count } do
      perform_enqueued_jobs(only: HardcoverSubscriptionSyncJob)
      Hardcover::ItemImporter.call
    end
    item = shelf.items.sole
    assert_equal [ 40_000, "known", true ], [ item.hardcover_book_id, item.state, item.baseline? ]
  end

  test "disconnecting and then connecting a different account also starts over" do
    connection = create_hardcover_connection(@user, hardcover_user_id: 1_001, auth_method: "personal_token", access_token: "old_pat")
    shelf = create_hardcover_subscription(@user, kind: "want_to_read", account_id: 1_001, automatic: true)
    create_hardcover_item(shelf, book_id: 1, state: "known", baseline: true)
    private_list = create_hardcover_subscription(@user, kind: "list", target_id: 70, account_id: 1_001, personal: true)
    public_list = create_hardcover_subscription(@user, kind: "list", target_id: 71, account_id: 1_001)

    Hardcover::ConnectionManager.disconnect!(connection)
    assert_nil HardcoverConnection.find_by(user_id: @user.id)
    assert_equal %w[paused paused active], [ shelf, private_list, public_list ].map { |subscription| subscription.reload.status }

    stub_accounts("new_pat" => [ 1_002, "second" ])
    Hardcover::ConnectionManager.connect!(user: @user.reload, auth_method: "personal_token", access_token: "new_pat")

    shelf.reload
    assert shelf.draft?
    assert_equal 1_002, shelf.hardcover_account_id
    assert_equal 0, shelf.items.count
    assert private_list.reload.paused?
    assert_equal HardcoverSubscription::PAUSE_OTHER_ACCOUNT, private_list.pause_reason
    assert public_list.reload.active?
  end

  test "reconnecting the same account resumes where it left off" do
    connection = create_hardcover_connection(@user, hardcover_user_id: 1_001, auth_method: "personal_token", access_token: "old_pat")
    shelf = create_hardcover_subscription(@user, kind: "want_to_read", account_id: 1_001, automatic: true)
    item = create_hardcover_item(shelf, book_id: 1, state: "known", baseline: true)
    private_list = create_hardcover_subscription(@user, kind: "list", target_id: 70, account_id: 1_001, personal: true)
    user_paused = create_hardcover_subscription(@user, kind: "list", target_id: 72, account_id: 1_001, personal: true)
    user_paused.pause!("Paused by you.")
    baseline = shelf.baseline_established_at

    Hardcover::ConnectionManager.disconnect!(connection)
    stub_accounts("fresh_pat" => [ 1_001, "same" ])
    Hardcover::ConnectionManager.connect!(user: @user.reload, auth_method: "personal_token", access_token: "fresh_pat")

    shelf.reload
    assert shelf.active?
    assert_equal baseline.to_i, shelf.baseline_established_at.to_i
    assert_equal [ item.id ], shelf.items.pluck(:id)
    assert private_list.reload.active?
    assert user_paused.reload.paused?, "a pause the user chose is kept"
  end

  test "a private list of another account resumes when its owner reconnects" do
    create_hardcover_connection(@user, hardcover_user_id: 1_001, auth_method: "personal_token", access_token: "first_pat")
    private_list = create_hardcover_subscription(@user, kind: "list", target_id: 70, account_id: 1_001, personal: true)
    stub_accounts("second_pat" => [ 1_002, "second" ], "first_again" => [ 1_001, "first" ])

    Hardcover::ConnectionManager.connect!(user: @user, auth_method: "personal_token", access_token: "second_pat")
    assert private_list.reload.paused?

    Hardcover::ConnectionManager.connect!(user: @user.reload, auth_method: "personal_token", access_token: "first_again")
    assert private_list.reload.active?
  end
end
