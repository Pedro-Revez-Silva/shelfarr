# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"
require_relative "../../test_helpers/kobo_household_test_helper"

class WebPreview::KoboAccountsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include WebPreviewTestHelper
  include KoboHouseholdTestHelper

  SECRETS = [ "synthetic-access", "synthetic-refresh", "synthetic-user-key", "synthetic-user-id", "synthetic-device", "synthetic-serial",
    KoboAccountTestHelper::WORKFLOW, DOWNLOAD_URL, FILE_URL, "private-book-url", "synthetic-signature" ].freeze

  setup do
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    setup_kobo_household
    @stranger = User.create!(username: "neighbour", name: "Neighbour", password: "Password123!x")
    ENV[WebPreview::Access::VARIABLE] = [ @owner, @recipient, @stranger ].map { |user| user.id.to_s }.join(",")
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    teardown_kobo_household
    FileUtils.remove_entry(@root) if @root
  end

  def send_json(method, path, user: @owner, **body)
    public_send(method, path, params: body, headers: account_headers(user), as: :json)
    response.parsed_body
  end

  def detail(account = @account, user: @owner)
    preview_get web_preview_api_kobo_account_path(account), user: user
    assert_response :success
    response.parsed_body.fetch("kobo_account")
  end

  def version(account = @account)
    WebPreview::KoboAccountJson.version(account.reload)
  end

  def assert_no_secrets
    SECRETS.each { |secret| assert_not_includes response.body, secret }
  end

  test "the list shows only your own connections and the catalogues shared with you, even to an administrator" do
    theirs = connect_kobo_account(user: @recipient, name: "Admin's own purchases")
    share_with
    sign_in_as(@owner)
    preview_get web_preview_api_kobo_accounts_path
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal({ "account" => @owner.id.to_s, "received" => [], "new_account" => { "name" => "My Kobo account" },
      "kobo_accounts" => [ { "id" => @account.id.to_s, "name" => "Family purchases", "state" => "connected", "status_label" => "Connected", "shared_with" => 1 } ] }, body)
    assert_no_secrets
    assert_not_includes response.body, "reader@example.test"

    sign_in_as(@recipient)
    preview_get web_preview_api_kobo_accounts_path, user: @recipient
    body = response.parsed_body
    assert_equal [ theirs.id.to_s ], body.fetch("kobo_accounts").map { |row| row.fetch("id") }
    assert_equal [ { "id" => @account.id.to_s, "name" => "Family purchases", "owner_name" => "User One", "sendable_count" => 1 } ], body.fetch("received")
    preview_get web_preview_api_kobo_account_path(@account), user: @recipient
    assert_response :not_found
    assert_equal "kobo_account_not_found", response.parsed_body.fetch("error")
    assert_no_enqueued_jobs only: KoboCatalogSyncJob do
      send_json(:post, web_preview_api_kobo_account_refresh_path(@account), user: @recipient)
      assert_response :not_found
      send_json(:post, web_preview_api_kobo_account_shares_path(@account), user: @recipient, recipient_id: @stranger.id.to_s)
      assert_response :not_found
      send_json(:post, web_preview_api_kobo_account_disconnect_path(@account), user: @recipient, version: version)
      assert_response :not_found
    end
    assert_equal 1, @account.kobo_account_shares.count
    assert KoboAccount.exists?(@account.id)
  end

  test "connecting shows the activation code once approved on Kobo, then refreshes the catalogue, without exposing credentials" do
    sign_in_as(@owner)
    stub_kobo_activation
    body = send_json(:post, web_preview_api_account_kobo_accounts_path, name: "  My purchased books  ")
    assert_response :created
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
    account = @owner.kobo_accounts.find_by!(name: "My purchased books")
    created = body.fetch("kobo_account")
    assert_equal [ account.id.to_s, "pending", nil, false, false, nil ], created.values_at("id", "state", "kobo_email", "refreshing", "can_refresh", "sharing")
    assert_equal "123456", created.dig("activation", "code")
    assert_equal "https://www.kobo.com/activate", created.dig("activation", "page")
    assert_in_delta 10.minutes.from_now, Time.iso8601(created.dig("activation", "expires_at")), 5
    assert_not_includes response.body, account.device_id
    assert_not_includes response.body, account.serial_number
    assert_not_includes response.body, KoboAccountTestHelper::POLL_PATH

    stub_request(:post, AUTH + POLL_PATH).to_return(body: { Status: "Pending" }.to_json)
    account.update!(next_poll_at: 1.second.ago)
    pending = send_json(:post, web_preview_api_kobo_account_poll_path(account)).fetch("kobo_account")
    assert_equal "pending", pending.fetch("state")

    stub_kobo_approval
    stub_kobo_tokens
    account.reload.update!(next_poll_at: 1.second.ago)
    approved = send_json(:post, web_preview_api_kobo_account_poll_path(account)).fetch("kobo_account")
    assert_response :success
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    assert_equal [ "connected", nil, "reader@example.test", true, false ], approved.values_at("state", "activation", "kobo_email", "refreshing", "can_refresh")
    assert_enqueued_with(job: KoboCatalogSyncJob, args: [ account.id, account.reload.sync_request_id ])
    assert_no_secrets
    assert_not_includes response.body, "123456"

    stub_kobo_catalogue
    KoboCatalogSyncJob.perform_now(account.id, account.sync_request_id)
    done = detail(account)
    assert_equal [ false, true ], done.values_at("refreshing", "can_refresh")
    assert done.fetch("last_synced_at")
    preview_get web_preview_api_kobo_catalogue_path(account)
    assert_equal [ [ "A Purchased Book", "An Author", { "tone" => "warning", "label" => "Format not supported" } ] ],
      response.parsed_body.dig("catalogue", "books").map { |book| book.values_at("title", "author", "eligibility") }
    assert_no_secrets
  end

  test "connecting refuses too many attempts with the classic sentence" do
    sign_in_as(@owner)
    3.times { |index| create_kobo_account(name: "Attempt #{index}") }
    body = send_json(:post, web_preview_api_account_kobo_accounts_path, name: "One more")
    assert_response :unprocessable_entity
    assert_equal({ "error" => "kobo_limit_reached", "message" => "Too many connections or recent sign-in attempts. Remove unused connections or wait a minute." }, body)
    send_json(:post, web_preview_api_account_kobo_accounts_path, name: 7)
    assert_response :bad_request
  end

  test "an expired code becomes an incomplete connection" do
    account = create_kobo_account(activation_expires_at: 1.second.ago)
    sign_in_as(@owner)
    body = send_json(:post, web_preview_api_kobo_account_poll_path(account))
    assert_response :success
    assert_equal [ "incomplete", "This sign-in code expired. Start a new connection.", nil ], body.fetch("kobo_account").values_at("state", "error", "activation")
  end

  test "a refresh is queued once and refused while one is running" do
    sign_in_as(@owner)
    body = nil
    assert_enqueued_with(job: KoboCatalogSyncJob) { body = send_json(:post, web_preview_api_kobo_account_refresh_path(@account)) }
    assert_response :success
    assert_equal "Catalogue refresh queued.", body.fetch("notice")
    assert_equal [ true, false ], body.fetch("kobo_account").values_at("refreshing", "can_refresh")
    assert_no_enqueued_jobs only: KoboCatalogSyncJob do
      body = send_json(:post, web_preview_api_kobo_account_refresh_path(@account))
    end
    assert_response :conflict
    assert_equal [ "refresh_refused", "A refresh is already running, or this account needs sign-in." ], body.values_at("error", "message")
    assert_equal true, body.dig("kobo_account", "refreshing")
  end

  test "the owner shares with chosen people and stops sharing, with the classic sentences" do
    sign_in_as(@owner)
    sharing = detail.fetch("sharing")
    assert_equal [], sharing.fetch("people")
    assert_equal [ [ @recipient.id.to_s, "Admin User (admin)" ], [ @stranger.id.to_s, "Neighbour (neighbour)" ] ], sharing.fetch("candidates").map(&:values)

    body = send_json(:post, web_preview_api_kobo_account_shares_path(@account), recipient_id: @recipient.id.to_s)
    assert_response :success
    assert_equal "Shared with Admin User. They can see this catalogue and send its DRM-free purchases to their own Kobo.", body.fetch("notice")
    share = @account.kobo_account_shares.sole
    people = body.dig("kobo_account", "sharing", "people")
    assert_equal [ [ share.id.to_s, "Admin User", "admin", false ] ], people.map { |person| person.values_at("id", "name", "username", "inactive") }
    assert_equal [ @stranger.id.to_s ], body.dig("kobo_account", "sharing", "candidates").map { |candidate| candidate.fetch("id") }
    assert_equal 1, body.dig("kobo_account", "shared_with")

    body = send_json(:post, web_preview_api_kobo_account_shares_path(@account), recipient_id: @recipient.id.to_s)
    assert_response :unprocessable_entity
    assert_equal [ "share_refused", "Recipient has already been taken" ], body.values_at("error", "message")
    body = send_json(:post, web_preview_api_kobo_account_shares_path(@account), recipient_id: @owner.id.to_s)
    assert_equal [ "share_refused", "Recipient must exist and Recipient must be an active Shelfarr user" ], body.values_at("error", "message")
    send_json(:post, web_preview_api_kobo_account_shares_path(@account), recipient_id: [ @stranger.id ])
    assert_response :bad_request
    assert_equal 1, @account.kobo_account_shares.count

    body = send_json(:post, web_preview_api_kobo_account_share_remove_path(@account, share))
    assert_response :success
    assert_equal "Admin User can no longer see this catalogue or receive its books. Copies already downloaded to their Kobo stay on that reader.", body.fetch("notice")
    assert_equal [], body.dig("kobo_account", "sharing", "people")
    body = send_json(:post, web_preview_api_kobo_account_share_remove_path(@account, share))
    assert_equal "That person no longer has access.", body.fetch("notice")
  end

  test "disconnecting needs the connection as the page showed it" do
    sign_in_as(@owner)
    shown = version
    share_with
    body = send_json(:post, web_preview_api_kobo_account_disconnect_path(@account), version: shown)
    assert_response :conflict
    assert_equal [ "kobo_account_changed", "This Kobo connection changed after the page was shown. Review it and choose again." ], body.values_at("error", "message")
    assert_equal 1, body.dig("kobo_account", "shared_with")
    assert KoboAccount.exists?(@account.id)

    body = send_json(:post, web_preview_api_kobo_account_disconnect_path(@account), version: version)
    assert_response :success
    assert_equal({ "account" => @owner.id.to_s, "disconnected" => @account.id.to_s, "notice" => WebPreview::KoboAccountsController::DISCONNECTED }, body)
    assert_not KoboAccount.exists?(@account.id)
    assert_equal 0, KoboAccountShare.count
    send_json(:post, web_preview_api_kobo_account_disconnect_path(@account), version: shown)
    assert_response :not_found
  end

  test "the disconnect version covers exactly the people the page listed, even when a share lands while it is built" do
    share_with
    sign_in_as(@owner)
    original = WebPreview::KoboAccountJson.method(:version)
    late = nil
    shown = WebPreview::KoboAccountJson.stub(:version, lambda { |account, *ids|
      late ||= share_with(@stranger)
      original.call(account, *ids)
    }) { detail }
    assert_equal [ "Admin User" ], shown.dig("sharing", "people").map { |person| person.fetch("name") }
    assert_equal 1, shown.fetch("shared_with")
    body = send_json(:post, web_preview_api_kobo_account_disconnect_path(@account), version: shown.fetch("version"))
    assert_response :conflict
    assert_equal 2, body.dig("kobo_account", "shared_with")
    assert_equal 2, @account.kobo_account_shares.count
  end

  test "a refusal that still shows an activation code is sent without a referrer" do
    account = create_kobo_account
    sign_in_as(@owner)
    body = send_json(:post, web_preview_api_kobo_account_refresh_path(account))
    assert_response :conflict
    assert_equal "123456", body.dig("kobo_account", "activation", "code")
    assert_equal [ "private, no-store", "no-referrer" ], response.headers.values_at("Cache-Control", "Referrer-Policy")
  end

  test "a share stopped while a copy is being sent refuses the send instead of failing" do
    share = share_with
    device, = recipient_device
    prepare_copy
    shown = WebPreview::KoboAccountJson.copy_version(@shared_book.ready_file)
    sign_in_as(@recipient)
    original = WebPreview::KoboAccountJson.method(:copy_version)
    WebPreview::KoboAccountJson.stub(:copy_version, lambda { |file|
      share.destroy! unless share.destroyed?
      original.call(file)
    }) do
      send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), user: @recipient, reader_id: device.id.to_s, copy: shown)
    end
    assert_response :not_found
    assert_equal "kobo_book_not_found", response.parsed_body.fetch("error")

    share = share_with
    stale = Kobo::HouseholdAccess.grant(@recipient, @account)
    lookup = Kobo::HouseholdAccess.method(:grant)
    lookups = 0
    first_stale = lambda { |viewer, account|
      lookups += 1
      lookups == 1 ? stale : lookup.call(viewer, account)
    }
    revoke = lambda { |file|
      share.destroy! unless share.destroyed?
      original.call(file)
    }
    WebPreview::KoboAccountJson.stub(:copy_version, revoke) do
      Kobo::HouseholdAccess.stub(:grant, first_stale) do
        send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), user: @recipient, reader_id: device.id.to_s, copy: shown)
      end
    end
    assert_response :not_found
    assert_equal "kobo_book_not_found", response.parsed_body.fetch("error")
    assert_equal 0, KoboDelivery.count
  end

  test "a copy replaced while it is being sent asks again instead of saying the share ended" do
    share_with
    device, = recipient_device
    file = prepare_copy
    shown = WebPreview::KoboAccountJson.copy_version(file)
    sign_in_as(@recipient)
    original = WebPreview::KoboAccountJson.method(:copy_version)
    replaced = lambda { |copy|
      version = original.call(copy)
      KoboAccountBookFile.where(id: file.id).delete_all if copy&.id == file.id
      version
    }
    body = WebPreview::KoboAccountJson.stub(:copy_version, replaced) do
      send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), user: @recipient, reader_id: device.id.to_s, copy: shown)
    end
    assert_response :conflict
    assert_equal "copy_changed", body.fetch("error")
    assert_equal 0, KoboDelivery.count
  end

  test "a reader disconnected while a copy is being sent says the reader is gone" do
    share_with
    device, = recipient_device
    file = prepare_copy
    shown = WebPreview::KoboAccountJson.copy_version(file)
    sign_in_as(@recipient)
    original = WebPreview::KoboAccountJson.method(:copy_version)
    gone = lambda { |copy|
      KoboDevice.where(id: device.id).delete_all
      original.call(copy)
    }
    body = WebPreview::KoboAccountJson.stub(:copy_version, gone) do
      send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), user: @recipient, reader_id: device.id.to_s, copy: shown)
    end
    assert_response :not_found
    assert_equal "reader_not_found", body.fetch("error")
    assert_equal 0, KoboDelivery.count
  end

  test "an existing copy stays sendable while a newer one is being prepared" do
    share_with
    device, = recipient_device
    file = prepare_copy
    @shared_book.kobo_account_book_files.create!(status: "fetching", request_id: SecureRandom.uuid, requested_by: @owner, started_at: Time.current)
    sign_in_as(@recipient)
    preview_get web_preview_api_kobo_book_path(@shared_book), user: @recipient
    copy = response.parsed_body.dig("book", "copy")
    assert_equal [ true, WebPreview::KoboAccountJson.copy_version(file) ], copy.values_at("preparing", "version")
    assert copy.fetch("ready")
    send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), user: @recipient, reader_id: device.id.to_s, copy: copy.fetch("version"))
    assert_response :success
    assert_equal file.id, device.kobo_deliveries.sole.kobo_account_book_file_id
  end

  test "catalogues are visible to the owner and to people they shared with, filtered and paged" do
    share_with
    @account.kobo_account_books.create!(entitlement_id: "locked", title: "A Protected Purchase", ownership_type: "purchased", rights: "protected", rights_checked_at: Time.current)
    51.times { |index| @account.kobo_account_books.create!(entitlement_id: "extra-#{index}", title: "Z Extra #{format('%02d', index)}") }
    sign_in_as(@recipient)
    preview_get web_preview_api_kobo_catalogue_path(@account), user: @recipient
    assert_response :success
    catalogue = response.parsed_body.fetch("catalogue")
    assert_equal({ "id" => @account.id.to_s, "name" => "Family purchases", "owner" => false, "owner_name" => "User One", "connected" => true, "last_synced_at" => nil }, catalogue.fetch("kobo_account"))
    assert_equal [ "all", 1, true, 53, 1, 50 ], catalogue.values_at("filter", "page", "more", "count", "sendable_count").push(catalogue.fetch("books").size)
    assert_equal({ "id" => @shared_book.id.to_s, "title" => "A Shared Purchase", "author" => "An Author", "eligibility" => { "tone" => "ok", "label" => "DRM-free EPUB · can be sent" } }, catalogue.fetch("books").second)
    preview_get web_preview_api_kobo_catalogue_path(@account, page: "2"), user: @recipient
    assert_equal [ 2, false, 3 ], response.parsed_body.fetch("catalogue").values_at("page", "more").push(response.parsed_body.dig("catalogue", "books").size)
    preview_get web_preview_api_kobo_catalogue_path(@account, filter: "sendable"), user: @recipient
    assert_equal [ "A Shared Purchase" ], response.parsed_body.dig("catalogue", "books").map { |book| book.fetch("title") }
    [ { page: "0" }, { page: "1e9" }, { filter: "everything" }, { page: "9999999" } ].each do |query|
      preview_get web_preview_api_kobo_catalogue_path(@account, **query), user: @recipient
      assert_response :bad_request, query.inspect
    end
    assert_no_secrets

    sign_in_as(@owner)
    preview_get web_preview_api_kobo_catalogue_path(@account)
    assert_equal true, response.parsed_body.dig("catalogue", "kobo_account", "owner")
    sign_in_as(@stranger)
    preview_get web_preview_api_kobo_catalogue_path(@account), user: @stranger
    assert_response :not_found
    assert_equal "catalogue_not_found", response.parsed_body.fetch("error")
  end

  test "a recipient prepares a private copy and sends it only to their own reader, bound to the copy the page showed" do
    share = share_with
    device, = recipient_device
    others, = recipient_device(@owner)
    sign_in_as(@recipient)
    preview_get web_preview_api_kobo_book_path(@shared_book), user: @recipient
    assert_response :success
    book = response.parsed_body.fetch("book")
    assert_equal [ "A Shared Purchase", "An Author", "User One's Kobo account “Family purchases”", nil, true ], book.values_at("title", "author", "from", "cover", "deliverable")
    assert_equal({ "id" => @account.id.to_s, "name" => "Family purchases", "owner" => false, "owner_name" => "User One" }, book.fetch("kobo_account"))
    assert_equal "EPUB3 · #{ActiveSupport::NumberHelper.number_to_human_size(synthetic_epub.bytesize)} according to Kobo", book.fetch("offered")
    assert_equal({ "version" => nil, "preparing" => false, "failure" => nil, "ready" => nil, "unavailable" => nil,
      "explanation" => "Shelfarr first saves a private copy of the DRM-free EPUB on this server, using User One's Kobo connection. Nobody else sees the sign-in. The copy is checked before it can be sent and stays out of the shared library." }, book.fetch("copy"))
    assert_equal [ { "id" => device.id.to_s, "name" => device.name, "status" => "Shelfarr books only", "older_copy" => false, "sent" => false } ], book.fetch("readers")

    send_json(:post, web_preview_api_kobo_book_prepare_path(@shared_book), user: @recipient)
    assert_response :bad_request
    body = nil
    assert_enqueued_with(job: KoboBookFetchJob) { body = send_json(:post, web_preview_api_kobo_book_prepare_path(@shared_book), user: @recipient, copy: nil) }
    assert_response :success
    assert_equal [ "Preparing a private copy. This usually takes under a minute.", true ], [ body.fetch("notice"), body.dig("book", "copy", "preparing") ]
    stub_book_metadata
    stub_book_download
    perform_enqueued_jobs only: KoboBookFetchJob
    preview_get web_preview_api_kobo_book_path(@shared_book), user: @recipient
    book = response.parsed_body.fetch("book")
    file = @shared_book.ready_file
    shown = WebPreview::KoboAccountJson.copy_version(file)
    assert_equal shown, book.dig("copy", "version")
    assert_equal [ false, false ], [ book.dig("copy", "preparing"), book.dig("copy", "ready", "stale") ]
    assert_match(/\AEPUB3 3\.0, /, book.dig("copy", "ready", "summary"))
    assert_equal "/kobo_books/#{@shared_book.id}/cover", book.fetch("cover")
    assert_no_secrets

    body = send_json(:post, web_preview_api_kobo_book_prepare_path(@shared_book), user: @recipient, copy: nil)
    assert_response :conflict
    assert_equal [ "copy_changed", shown ], [ body.fetch("error"), body.dig("book", "copy", "version") ]
    send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), user: @recipient, reader_id: others.id.to_s, copy: shown)
    assert_response :not_found
    assert_equal "reader_not_found", response.parsed_body.fetch("error")
    send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), user: @recipient, reader_id: device.id.to_s, copy: nil)
    assert_response :conflict
    assert_equal 0, KoboDelivery.count

    body = send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), user: @recipient, reader_id: device.id.to_s, copy: shown)
    assert_response :success
    assert_equal "Queued for #{device.name}. Sync that Kobo over Wi-Fi to download it.", body.fetch("notice")
    delivery = device.kobo_deliveries.sole
    assert_equal [ share.id, file.id ], [ delivery.kobo_account_share_id, delivery.kobo_account_book_file_id ]
    assert_equal [ "Queued · waiting for the reader's next sync", true ], body.dig("book", "readers", 0).values_at("status", "sent")
    assert_equal 0, others.kobo_deliveries.count

    share.destroy!
    [ [ :get, web_preview_api_kobo_book_path(@shared_book) ], [ :post, web_preview_api_kobo_book_prepare_path(@shared_book) ],
      [ :post, web_preview_api_kobo_book_deliver_path(@shared_book) ], [ :get, web_preview_api_kobo_catalogue_path(@account) ] ].each do |verb, path|
      send_json(verb, path, user: @recipient, reader_id: device.id.to_s, copy: shown)
      assert_response :not_found, path
    end
  end

  test "an owner's copy says when Kobo needs sign-in again, and a refused copy keeps the classic reason" do
    sign_in_as(@owner)
    @account.update!(status: "reauthorization_required")
    preview_get web_preview_api_kobo_book_path(@shared_book)
    copy = response.parsed_body.dig("book", "copy")
    assert_equal [ "Reconnect this Kobo account to prepare a copy.", nil ], copy.values_at("unavailable", "explanation")
    body = send_json(:post, web_preview_api_kobo_book_prepare_path(@shared_book), copy: nil)
    assert_response :unprocessable_entity
    assert_equal [ "prepare_refused", KoboAccountBookFile::ERROR_MESSAGES.fetch("reauthorization_required") ], body.values_at("error", "message")
    send_json(:post, web_preview_api_kobo_book_deliver_path(@shared_book), reader_id: "", copy: nil)
    assert_response :bad_request
  end

  test "every write checks the signed-in account and the page's security token" do
    sign_in_as(@owner)
    send_json(:post, web_preview_api_kobo_account_refresh_path(@account), user: @recipient)
    assert_response :unauthorized
    assert_equal "account_changed", response.parsed_body.fetch("error")
    with_forgery_protection do
      token = csrf_token
      assert_no_enqueued_jobs only: KoboCatalogSyncJob do
        post web_preview_api_kobo_account_refresh_path(@account), params: {}, headers: account_headers(@owner), as: :json
      end
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      assert_enqueued_with(job: KoboCatalogSyncJob) do
        post web_preview_api_kobo_account_refresh_path(@account), params: {}, headers: account_headers(@owner).merge("X-CSRF-Token" => token), as: :json
      end
      assert_response :success
    end
    ENV[WebPreview::Access::VARIABLE] = @recipient.id.to_s
    preview_get web_preview_api_kobo_accounts_path
    assert_response :not_found
  end

  test "classic Kobo account pages open the warm pages for preview users and stay classic otherwise" do
    share_with
    sign_in_as(@owner)
    get kobo_accounts_path
    assert_redirected_to "/preview/account/devices#kobo-accounts"
    get kobo_account_path(@account, filter: "sendable", page: "2", extra: "x")
    assert_redirected_to "/preview/account/devices/kobo-accounts/#{@account.id}?filter=sendable&page=2"
    get kobo_account_path(@account, filter: "nonsense", page: "-1")
    assert_redirected_to "/preview/account/devices/kobo-accounts/#{@account.id}"
    get kobo_shared_library_path(@account)
    assert_redirected_to "/preview/account/devices/kobo-accounts/#{@account.id}"
    get kobo_account_book_path(@shared_book)
    assert_redirected_to "/preview/account/devices/kobo-books/#{@shared_book.id}"
    theirs = connect_kobo_account(user: @stranger, name: "Neighbour's books")
    get kobo_account_path(theirs)
    assert_response :not_found
    get kobo_shared_library_path(theirs)
    assert_response :not_found

    post sync_kobo_account_path(@account)
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "Family purchases"

    sign_in_as(@recipient)
    get kobo_shared_libraries_path
    assert_redirected_to "/preview/account/devices#kobo-shared"
    get kobo_shared_library_path(@account, page: "3")
    assert_redirected_to "/preview/account/devices/kobo-shared/#{@account.id}?page=3"
    get kobo_account_book_path(@shared_book)
    assert_redirected_to "/preview/account/devices/kobo-books/#{@shared_book.id}"
    get web_preview_kobo_shared_path(@account)
    assert_response :success

    ENV[WebPreview::Access::VARIABLE] = @stranger.id.to_s
    get kobo_shared_libraries_path
    assert_response :success
    get kobo_shared_library_path(@account)
    assert_response :success
    get kobo_account_book_path(@shared_book)
    assert_response :success
    get web_preview_kobo_book_path(@shared_book)
    assert_response :not_found
  end
end
