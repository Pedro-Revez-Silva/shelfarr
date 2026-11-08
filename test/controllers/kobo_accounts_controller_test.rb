# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_account_test_helper"

class KoboAccountsControllerTest < ActionDispatch::IntegrationTest
  include KoboAccountTestHelper
  include ActiveJob::TestHelper

  setup { sign_in_as(users(:one)) }

  test "profile links to account setup and creating a connection shows its code with no-store" do
    get profile_path
    assert_select "a[href=?]", kobo_accounts_path, text: "Kobo accounts"
    stub_kobo_activation
    post kobo_accounts_path, params: { name: "My purchased books" }
    account = users(:one).kobo_accounts.sole
    assert_redirected_to kobo_account_path(account)
    follow_redirect!
    assert_response :ok
    assert_select "[data-testid=kobo-activation-code]", text: "123456"
    assert_select "a[href='https://www.kobo.com/activate'][rel='noopener noreferrer']"
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_not_includes response.body, WORKFLOW
    assert_not_includes response.body, account.device_id
    assert_not_includes response.body, account.serial_number
  end

  test "only the owner can view approve refresh or disconnect an account" do
    other = connect_kobo_account(user: users(:two), name: "Other person's private account")
    other.kobo_account_books.create!(entitlement_id: "secret-book", title: "Other person's purchase")
    get kobo_accounts_path
    assert_not_includes response.body, other.name
    get kobo_account_path(other)
    assert_response :not_found
    post poll_kobo_account_path(other), as: :json
    assert_response :not_found
    post sync_kobo_account_path(other)
    assert_response :not_found
    delete kobo_account_path(other)
    assert_response :not_found
    assert KoboAccount.exists?(other.id)
    assert_no_enqueued_jobs only: KoboCatalogSyncJob
  end

  test "approval redirects to its account and never exposes access tokens to the browser" do
    account = create_kobo_account
    stub_kobo_approval
    stub_kobo_tokens
    post poll_kobo_account_path(account), as: :json
    assert_response :ok
    assert_equal "approved", response.parsed_body.fetch("status")
    assert_enqueued_with(job: KoboCatalogSyncJob, args: [ account.id, account.reload.sync_request_id ])
    post poll_kobo_account_path(account, phase: "catalogue"), as: :json
    assert_equal "pending", response.parsed_body.fetch("status")
    stub_kobo_catalogue
    KoboCatalogSyncJob.perform_now(account.id, account.sync_request_id)
    post poll_kobo_account_path(account), as: :json
    assert_equal "approved", response.parsed_body.fetch("status")
    assert_equal kobo_account_path(account), response.parsed_body.fetch("redirect_url")
    get kobo_account_path(account)
    assert_select "h2", text: "Connected to Kobo"
    assert_select "body", text: /A Purchased Book/
    assert_select "body", text: /Catalogue only/
    assert_not_includes response.body, "synthetic-access"
    assert_not_includes response.body, "synthetic-refresh"
    assert_not_includes response.body, "synthetic-user-key"
    assert_not_includes response.body, "123456"
    assert_not_includes response.body, "private-book-url"
  end

  test "refresh is owner scoped paginated and HTML escaped" do
    account = connect_kobo_account
    51.times { |index| account.kobo_account_books.create!(entitlement_id: index.to_s, title: "Book #{format('%02d', index)}") }
    account.kobo_account_books.first.update!(title: "<script>attack</script>")
    get kobo_account_path(account)
    assert_select "nav a", text: "Next"
    assert_includes response.body, "&lt;script&gt;attack&lt;/script&gt;"
    assert_not_includes response.body, "<script>attack</script>"
    get kobo_account_path(account, page: 2)
    assert_select "nav a", text: "Previous"
    assert_select "nav a", text: "Next", count: 0
    assert_enqueued_with(job: KoboCatalogSyncJob) { post sync_kobo_account_path(account) }
  end

  test "disconnect removes stored credentials and catalogue without changing physical reader selections" do
    account = connect_kobo_account
    account.kobo_account_books.create!(entitlement_id: "book", title: "Private book")
    assert_no_difference [ "KoboDevice.count", "KoboDelivery.count", "Book.count" ] do
      assert_difference [ "KoboAccount.count", "KoboAccountBook.count" ], -1 do
        delete kobo_account_path(account)
      end
    end
    assert_redirected_to kobo_accounts_path
  end

  test "all account endpoints require a Shelfarr session" do
    account = connect_kobo_account
    sign_out
    get kobo_accounts_path
    assert_response :redirect
    get kobo_account_path(account)
    assert_response :redirect
    post kobo_accounts_path, params: { name: "Reader" }
    assert_response :redirect
    post poll_kobo_account_path(account), as: :json
    assert_response :redirect
    post sync_kobo_account_path(account)
    assert_response :redirect
    delete kobo_account_path(account)
    assert_response :redirect
    assert KoboAccount.exists?(account.id)
  end

  test "codes that expire show a recovery path and do not create a catalogue" do
    account = create_kobo_account(activation_expires_at: 1.minute.ago)
    post poll_kobo_account_path(account), as: :json
    assert_equal "failed", response.parsed_body.fetch("status")
    get kobo_account_path(account)
    assert_select "[role=alert]", text: /code expired/
    assert_select "[data-testid=kobo-activation-code]", count: 0
    assert_select "a", text: "← Kobo accounts"
    assert_equal 0, account.kobo_account_books.count
  end

  test "private credentials are filtered from parameter logging" do
    values = { activation_code: "synthetic-code", activation_poll_url: "synthetic-url", kobo_user_id: "synthetic-user", kobo_user_key: "synthetic-key",
      kobo_email: "reader@example.test", device_id: "synthetic-device", serial_number: "synthetic-serial", access_token: "synthetic-access", refresh_token: "synthetic-refresh" }
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(values)
    values.each_key { |key| assert_equal "[FILTERED]", filtered.fetch(key) }
  end

  test "HTML checks and deployment subpaths work without exposing the provider workflow" do
    account = create_kobo_account
    stub_kobo_approval
    stub_kobo_tokens
    post poll_kobo_account_path(account), env: { "SCRIPT_NAME" => "/shelfarr" }
    assert_redirected_to "/shelfarr/kobo_accounts/#{account.id}"
    get "/kobo_accounts/#{account.id}", env: { "SCRIPT_NAME" => "/shelfarr" }
    assert_response :success
    assert_select "a[href='/shelfarr/kobo_accounts']"
    assert_select "[data-kobo-account-url-value='/shelfarr/kobo_accounts/#{account.id}/poll?phase=catalogue']"
    assert_not_includes response.body, WORKFLOW
  end

  test "disconnect succeeds when a catalogue worker updates the account after controller lookup" do
    account = connect_kobo_account(sync_status: "queued", sync_request_id: "request-1", sync_started_at: Time.current)
    account.kobo_account_books.create!(entitlement_id: "book", title: "Private book")
    injected = false
    callback = -> do
      KoboAccount.find(@account.id).update!(sync_status: "syncing")
      injected = true
    end
    KoboAccountsController.before_action(callback, only: :destroy)
    delete kobo_account_path(account)
    assert injected
    assert_redirected_to kobo_accounts_path
    assert_not KoboAccount.exists?(account.id)
    assert_equal 0, KoboAccountBook.where(kobo_account_id: account.id).count
  ensure
    KoboAccountsController.skip_before_action(callback) if callback
  end

  test "a connection removed after lookup does not turn disconnect into an error" do
    account = connect_kobo_account
    callback = -> { KoboAccount.find(@account.id).destroy! }
    KoboAccountsController.before_action(callback, only: :destroy)
    delete kobo_account_path(account)
    assert_redirected_to kobo_accounts_path
    assert_not KoboAccount.exists?(account.id)
  ensure
    KoboAccountsController.skip_before_action(callback) if callback
  end
end
