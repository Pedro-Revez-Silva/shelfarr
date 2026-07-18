# frozen_string_literal: true

require "test_helper"

class Admin::OwnedLibraryConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_audiobook_output_path = SettingsService.get(:audiobook_output_path)
    @audiobook_output_path = Dir.mktmpdir("audible-controller-storage")
    SettingsService.set(:audiobook_output_path, @audiobook_output_path)
    sign_in_as(users(:two))
  end

  teardown do
    SettingsService.set(:audiobook_output_path, @original_audiobook_output_path)
    FileUtils.rm_rf(@audiobook_output_path)
  end

  test "index shows a disabled default without persisting it" do
    get admin_owned_library_connections_url

    assert_response :success
    assert_select "h1", "Audible Backup"
    assert_select "[role='note']", text: /Imported backups join Shelfarr's shared Library/
    assert_select "a", text: "Open Library", count: 0
    assert_select "input[name='owned_library_connection[enabled]'][checked]", count: 0
    assert_equal 0, OwnedLibraryConnection.count
  end

  test "index honors the temporary tab query used by Turbo redirects" do
    get admin_owned_library_connections_url(tab: "automation")

    assert_response :success
    assert_select "#audible-backup-tabs[data-settings-tabs-active-value='automation']"
    assert_equal 0, OwnedLibraryConnection.count
  end

  test "index provides a no-JavaScript fallback and singly labelled controls" do
    connection = create_connection

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url
    end

    assert_response :success
    assert_select "noscript", text: /refresh this page manually/
    assert_select "[role='tablist'] [role='tab'][class~='px-2'][class~='sm:px-4']", count: 4
    assert_select "label input#owned_library_connection_enabled[aria-describedby='audible-enabled-help']", count: 1
    assert_select "label[for='owned_library_connection_enabled']", count: 0
    assert_select "label input#owned_library_connection_allow_private_network[aria-describedby='audible-private-network-help']", count: 1
    assert_select "label input#owned_library_connection_scheduled_sync_enabled[aria-describedby='scheduled-audible-sync-help']", count: 1
    assert_select "label input#owned_library_connection_automatic_backup_enabled[aria-describedby='automatic-backup-context automatic-backup-help']", count: 1
    assert_select "h2#audible-account-heading", text: "Audible account"
  end

  test "unsynced and filtered catalog empty states explain the next action" do
    connection = create_connection

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url(tab: "catalog")
    end

    assert_response :success
    assert_select "p", text: "No Audible catalog has been synced yet."
    assert_select "a[href='#{admin_owned_library_connections_path(anchor: 'overview')}']", text: "Run the first library sync"

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url(tab: "catalog", q: "missing title")
    end

    assert_response :success
    assert_select "p", text: "No Audible titles match this filter."
  end

  test "catalog exposes failed backup detail without hover" do
    connection = create_connection
    connection.update!(last_synced_at: 1.minute.ago)
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Failed Catalog Backup",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "failed",
      error_message: "Libation could not decrypt this purchase"
    )

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url(tab: "catalog")
    end

    assert_response :success
    assert_select "details" do
      assert_select "summary", text: "Failed"
      assert_select "p", text: "Libation could not decrypt this purchase"
    end
  end

  test "create stores a disabled connection and encrypts manual token" do
    assert_difference -> { OwnedLibraryConnection.count }, 1 do
      post admin_owned_library_connections_url, params: {
        owned_library_connection: {
          url: "https://libation.test",
          bridge_token: "manual-token",
          enabled: "0",
          allow_private_network: "0",
          timeout_seconds: "30"
        }
      }, headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    connection = OwnedLibraryConnection.first
    assert_equal "manual-token", connection.bridge_token
    assert_not_equal "manual-token", connection.bridge_token_before_type_cast
    assert_not connection.enabled?
  end

  test "changing a custom URL requires a new matching token" do
    connection = create_connection

    patch admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        url: "https://different-libation.test",
        bridge_token: "",
        enabled: "1",
        allow_private_network: "0",
        timeout_seconds: "30"
      }
    }

    assert_response :unprocessable_entity
    assert_select "li", text: /Bridge token is required/
    assert_equal "https://libation.test", connection.reload.url
    assert_equal "token", connection.bridge_token
  end

  test "leaving the token blank keeps it when the custom URL is unchanged" do
    connection = create_connection

    patch admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        url: connection.url,
        bridge_token: "",
        enabled: "1",
        allow_private_network: "0",
        timeout_seconds: "45"
      }
    }, headers: { "HTTP_REFERER" => "http://[malformed" }

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_equal "token", connection.reload.bridge_token
    assert_equal 45, connection.timeout_seconds
  end

  test "connection test commits version state and ignores a hostile referrer" do
    connection = create_connection

    VCR.turned_off do
      stub_request(:get, "https://libation.test/health")
        .to_return(status: 200, body: { status: "ok" }.to_json)
      stub_request(:get, "https://libation.test/version")
        .to_return(
          status: 200,
          body: { companionVersion: "1.2.3", libationVersion: "13.5.0" }.to_json
        )

      post test_admin_owned_library_connection_url(connection),
        headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_equal "1.2.3", connection.reload.companion_version
    assert_equal "13.5.0", connection.provider_version
  end

  test "enabling Audible Backup fails before saving on unsupported audiobook storage" do
    storage_error = -> { raise OwnedMediaImportFileService::Error, "hard links unavailable" }

    OwnedMediaImportFileService.stub(:verify_filesystem_capabilities!, storage_error) do
      post admin_owned_library_connections_url, params: {
        owned_library_connection: {
          url: "https://libation.test",
          bridge_token: "manual-token",
          enabled: "1",
          allow_private_network: "0",
          timeout_seconds: "30"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/Audiobook storage is not ready/, response.body)
    assert_equal 0, OwnedLibraryConnection.count
  end

  test "connection settings cannot change during a pending Audible sign-in" do
    connection = create_connection
    connection.update!(
      auth_session_id: "session-1",
      auth_login_url: "https://www.amazon.com/ap/signin?example=1",
      auth_expires_at: 10.minutes.from_now
    )

    patch admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        url: "https://replacement-libation.test",
        bridge_token: "replacement-token",
        enabled: "1",
        allow_private_network: "0",
        timeout_seconds: "30"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_match(/sign-in to finish/, flash[:alert])
    assert_equal "https://libation.test", connection.reload.url
    assert connection.auth_pending?
  end

  test "queued backlog blocks companion identity changes but permits disabling" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Queued Account-Bound Title",
      ownership_type: "purchased"
    )
    pending_import = item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "pending",
      automatic: true
    )

    patch admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        url: "https://replacement-libation.test",
        bridge_token: "replacement-token",
        enabled: "1",
        allow_private_network: "0",
        timeout_seconds: "30"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_match(/queued Audible backups/, flash[:alert])
    assert_equal "https://libation.test", connection.reload.url
    assert_equal "token", connection.bridge_token

    patch admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        url: connection.url,
        bridge_token: "",
        enabled: "0",
        allow_private_network: "0",
        timeout_seconds: "45"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_not connection.reload.enabled?
    assert_equal 45, connection.timeout_seconds
    assert pending_import.reload.pending?
  end

  test "blank companion URL cannot bypass identity-change guards by falling back to the managed endpoint" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Queued Account-Bound Title",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "pending",
      automatic: true
    )

    patch admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        url: "",
        bridge_token: "",
        enabled: "1",
        allow_private_network: "1",
        timeout_seconds: "30"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_match(/queued Audible backups/, flash[:alert])
    assert_equal "https://libation.test", connection.reload.url
    assert_equal "token", connection.bridge_token
    assert item.reload.active?
  end

  test "recoverable failed backup blocks companion identity changes" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Recoverable Account-Bound Title",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "failed",
      destination_path: "/audiobooks/recoverable-account-bound-title.m4b",
      completed_at: Time.current
    )

    patch admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        url: "https://replacement-libation.test",
        bridge_token: "replacement-token",
        enabled: "1",
        allow_private_network: "0",
        timeout_seconds: "30"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_match(/recoverable Audible backups/, flash[:alert])
    assert_equal "https://libation.test", connection.reload.url
    assert_equal "token", connection.bridge_token
    assert item.reload.active?
  end

  test "a backlog admitted immediately before an endpoint update wins the connection transition" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Raced Account-Bound Title",
      ownership_type: "purchased"
    )
    admission_connection = OwnedLibraryConnection.find(connection.id)
    backlog_connection = OwnedLibraryConnection.find(connection.id)
    acquire_after_backlog = admission_connection.method(:with_lock)
    transition = lambda do |&block|
      backlog_connection.with_lock do
        item.owned_media_imports.create!(
          requested_by: users(:two),
          status: "pending",
          automatic: true
        )
      end
      acquire_after_backlog.call(&block)
    end

    OwnedLibraryConnection.stub(:find, admission_connection) do
      admission_connection.stub(:with_lock, transition) do
        patch admin_owned_library_connection_url(connection), params: {
          owned_library_connection: {
            url: "https://replacement-libation.test",
            bridge_token: "replacement-token",
            enabled: "1",
            allow_private_network: "0",
            timeout_seconds: "30"
          }
        }
      end
    end

    assert_match(/queued Audible backups/, flash[:alert])
    assert_equal "https://libation.test", connection.reload.url
    assert_equal 1, connection.owned_media_imports.pending.count
  end

  test "an endpoint update invalidates the old account baseline before later backlog admission" do
    connection = create_connection
    connection.update!(
      last_synced_at: 1.day.ago,
      backlog_backup_decided_at: 1.day.ago,
      automatic_backup_enabled: true,
      automatic_backup_user: users(:two)
    )
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Old Account Title",
      ownership_type: "purchased"
    )

    patch admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        url: "https://replacement-libation.test",
        bridge_token: "replacement-token",
        enabled: "1",
        allow_private_network: "0",
        timeout_seconds: "30"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    connection.reload
    assert_equal "https://replacement-libation.test", connection.url
    assert_nil connection.last_synced_at
    assert_nil connection.backlog_backup_decided_at
    assert_not connection.automatic_backup_enabled?
    assert_not item.reload.active?
    assert_raises(OwnedLibraryBacklogBackup::ConnectionUnavailable) do
      OwnedLibraryBacklogBackup.call(
        connection: connection,
        requested_by: users(:two),
        confirmed: true
      )
    end
    assert_equal 0, item.owned_media_imports.count
  end

  test "queued backlog blocks starting authentication for a different Audible account" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Queued Account-Bound Title",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "pending",
      automatic: true
    )

    VCR.turned_off do
      post auth_start_admin_owned_library_connection_url(connection), params: {
        account: "different@example.com",
        locale: "us"
      }
      assert_not_requested :post, "https://libation.test/v1/auth/start"
    end

    assert_match(/queued Audible backups/, flash[:alert])
    assert_nil connection.reload.auth_session_id
  end

  test "recoverable failed backup blocks authentication for a different Audible account" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Recoverable Account-Bound Title",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "failed",
      destination_path: "/audiobooks/recoverable-auth-title.m4b",
      completed_at: Time.current
    )

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/start")
        .to_return(
          status: 200,
          body: {
            sessionId: "session-1",
            loginUrl: "https://www.amazon.com/ap/signin?example=1",
            expiresAt: 10.minutes.from_now.iso8601
          }.to_json
        )

      post auth_start_admin_owned_library_connection_url(connection), params: {
        account: "different@example.com",
        locale: "us"
      }

      assert_not_requested :post, "https://libation.test/v1/auth/start"
    end

    assert_match(/recoverable Audible backups/, flash[:alert])
    assert_nil connection.reload.auth_session_id
  end

  test "library is searchable and paginated without a hard cap" do
    connection = create_connection
    51.times do |index|
      connection.owned_library_items.create!(
        external_id: format("B%09d", index),
        title: format("Title %02d", index),
        authors: [ index == 50 ? "Needle Author" : "Other Author" ]
      )
    end

    VCR.turned_off do
      stub_accounts(connection)

      get admin_owned_library_connections_url(page: 2)
      assert_response :success
      assert_select "tbody tr", count: 1
      assert_select "a", text: "Previous"

      get admin_owned_library_connections_url(q: "Needle Author")
      assert_response :success
      assert_select "tbody tr", count: 1
      assert_select "td", text: /Title 50/
    end
  end

  test "auth start renders only a validated Audible login URL" do
    connection = create_connection

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/start")
        .to_return(
          status: 200,
          body: {
            sessionId: "session-1",
            loginUrl: "https://www.amazon.com/ap/signin?example=1",
            expiresAt: 10.minutes.from_now.iso8601
          }.to_json
        )

      post auth_start_admin_owned_library_connection_url(connection),
        params: { account: "reader@example.com", locale: "us" },
        headers: { "HTTP_REFERER" => "http://[malformed" }

      assert_not_requested :get, "https://libation.test/v1/accounts"
    end

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control", ""), "no-store"
    assert_select "a[href='https://www.amazon.com/ap/signin?example=1']", text: /Open secure Audible sign-in/
    assert_select "input[name='response_url']"
    assert_select "input[name='auth_session_id'][value='session-1']"

    connection.reload
    assert connection.auth_pending?
    assert_not_equal "session-1", connection.auth_session_id_before_type_cast

    VCR.turned_off do
      get admin_owned_library_connections_url
    end
    assert_response :success
    assert_includes response.headers.fetch("Cache-Control", ""), "no-store"
    assert_select "a[href='https://www.amazon.com/ap/signin?example=1']", text: /Open secure Audible sign-in/
  end

  test "auth start records a durable starting claim before calling the companion" do
    connection = create_connection
    client = Object.new
    client.define_singleton_method(:token_file_managed?) { false }
    client.define_singleton_method(:start_auth) do |account:, locale:|
      raise "missing starting claim" unless connection.reload.auth_starting?
      raise "unexpected account" unless account == "reader@example.com" && locale == "us"

      LibationCompanionClient::AuthSession.new(
        "session-1",
        "https://www.amazon.com/ap/signin?example=1",
        10.minutes.from_now,
        false,
        {}
      )
    end

    LibationCompanionClient.stub(:new, client) do
      post auth_start_admin_owned_library_connection_url(connection),
        params: { account: "reader@example.com", locale: "us" }
    end

    assert_response :success
    assert connection.reload.auth_pending?
    assert_not connection.auth_starting?
  end

  test "auth start releases its durable claim when the companion request fails" do
    connection = create_connection
    client = Object.new
    client.define_singleton_method(:start_auth) do |**|
      raise LibationCompanionClient::ConnectionError, "offline"
    end

    LibationCompanionClient.stub(:new, client) do
      post auth_start_admin_owned_library_connection_url(connection),
        params: { account: "reader@example.com", locale: "us" }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    connection.reload
    assert_nil connection.auth_session_id
    assert_nil connection.auth_expires_at
  end

  test "auth completion uses and clears the encrypted pending session" do
    connection = create_connection
    connection.update!(
      auth_session_id: "session-1",
      auth_login_url: "https://www.amazon.com/ap/signin?example=1",
      auth_expires_at: 10.minutes.from_now
    )

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/complete")
        .with do |request|
          JSON.parse(request.body) == {
            "sessionId" => "session-1",
            "responseUrl" => "https://www.amazon.com/ap/maplanding?example=1"
          }
        end
        .to_return(status: 204)

      post auth_complete_admin_owned_library_connection_url(connection),
        params: {
          auth_session_id: "session-1",
          response_url: "https://www.amazon.com/ap/maplanding?example=1"
        },
        headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_not connection.reload.auth_pending?
    assert_nil connection.auth_session_id
    assert_nil connection.auth_login_url
  end

  test "auth completion invalidates ownership and automation state from the previous account" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Previous Account Purchase",
      ownership_type: "purchased"
    )
    connection.update!(
      last_synced_at: 1.day.ago,
      backlog_backup_decided_at: 1.day.ago,
      scheduled_sync_enabled: true,
      automatic_backup_enabled: true,
      automatic_backup_user: users(:two),
      automatic_backup_enabled_at: 1.day.ago,
      auth_session_id: "replacement-account-session",
      auth_login_url: "https://www.amazon.com/ap/signin?replacement=1",
      auth_expires_at: 10.minutes.from_now
    )

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/complete")
        .to_return(status: 204)

      post auth_complete_admin_owned_library_connection_url(connection),
        params: {
          auth_session_id: "replacement-account-session",
          response_url: "https://www.amazon.com/ap/maplanding?replacement=1"
        }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_not item.reload.active?, "ownership from the previously synced Audible account must become stale"
    connection.reload
    assert_nil connection.last_synced_at
    assert_nil connection.backlog_backup_decided_at
    assert_not connection.automatic_backup_enabled?
    assert_nil connection.automatic_backup_user
    assert_nil connection.automatic_backup_enabled_at
    assert_nil connection.auth_session_id
  end

  test "auth completion does not call the companion for a replaced session" do
    connection = create_connection
    connection.update!(
      auth_session_id: "session-new",
      auth_login_url: "https://www.amazon.com/ap/signin?new=1",
      auth_expires_at: 10.minutes.from_now
    )
    client = Object.new
    client.define_singleton_method(:complete_auth) { |**| raise "companion must not be called" }

    LibationCompanionClient.stub(:new, client) do
      post auth_complete_admin_owned_library_connection_url(connection),
        params: {
          auth_session_id: "session-old",
          response_url: "https://www.amazon.com/ap/maplanding?old=1"
        }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_match(/session expired/, flash[:alert])
    connection.reload
    assert_equal "session-new", connection.auth_session_id
    assert_equal "https://www.amazon.com/ap/signin?new=1", connection.auth_login_url
  end

  test "an older auth completion cannot clear a newer session installed while it is in flight" do
    connection = create_connection
    connection.update!(
      auth_session_id: "session-old",
      auth_login_url: "https://www.amazon.com/ap/signin?old=1",
      auth_expires_at: 10.minutes.from_now
    )
    client = Object.new
    client.define_singleton_method(:complete_auth) do |session_id:, response_url:|
      raise "wrong session" unless session_id == "session-old"
      raise "wrong response URL" unless response_url == "https://www.amazon.com/ap/maplanding?old=1"

      OwnedLibraryConnection.find(connection.id).update!(
        auth_session_id: "session-new",
        auth_login_url: "https://www.amazon.com/ap/signin?new=1",
        auth_expires_at: 10.minutes.from_now
      )
    end

    LibationCompanionClient.stub(:new, client) do
      post auth_complete_admin_owned_library_connection_url(connection),
        params: {
          auth_session_id: "session-old",
          response_url: "https://www.amazon.com/ap/maplanding?old=1"
        }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    connection.reload
    assert_equal "session-new", connection.auth_session_id
    assert_equal "https://www.amazon.com/ap/signin?new=1", connection.auth_login_url
    assert connection.auth_pending?
  end

  test "stale auth cleanup cannot clear a newer session installed before its lock" do
    connection = create_connection
    connection.update!(
      auth_session_id: "session-stale",
      auth_login_url: "https://www.amazon.com/ap/signin?stale=1",
      auth_expires_at: 1.minute.ago
    )
    original_clear = connection.method(:clear_auth_state_if_current!)
    connection.define_singleton_method(:clear_auth_state_if_current!) do |auth_state|
      OwnedLibraryConnection.find(id).update!(
        auth_session_id: "session-new",
        auth_login_url: "https://www.amazon.com/ap/signin?new=1",
        auth_expires_at: 10.minutes.from_now
      )
      original_clear.call(auth_state)
    end
    relation = Object.new
    relation.define_singleton_method(:first_or_initialize) { |*_args, **_kwargs, &_block| connection }

    OwnedLibraryConnection.stub(:for_provider, relation) do
      get admin_owned_library_connections_url
    end

    assert_response :success
    connection.reload
    assert_equal "session-new", connection.auth_session_id
    assert_equal "https://www.amazon.com/ap/signin?new=1", connection.auth_login_url
    assert connection.auth_pending?
    assert_select "input[name='auth_session_id'][value='session-new']"
  end

  test "active sync displays a busy state without probing accounts" do
    connection = create_connection
    connection.update!(sync_status: "syncing", sync_job_id: "sync-1", sync_started_at: Time.current)

    VCR.turned_off do
      get admin_owned_library_connections_url
      assert_not_requested :get, "https://libation.test/v1/accounts"
    end

    assert_response :success
    assert_select "#audible-sync-status[data-state='syncing'][role='status'][aria-live='polite'][aria-atomic='true']", text: /Syncing your Audible library/
    assert_select "[data-controller='elapsed-time'][aria-live='off'] [aria-hidden='true'] [data-elapsed-time-target='output']"
    assert_select "div", text: /configured but unavailable/, count: 0
  end

  test "a long healthy sync uses its heartbeat instead of looking recoverable" do
    connection = create_connection
    connection.update!(
      sync_status: "syncing",
      sync_job_id: connection.sync_job_state_value(
        job_id: "sync-1",
        poll_token: "healthy-poll-chain"
      ),
      sync_started_at: 30.minutes.ago
    )

    VCR.turned_off do
      get admin_owned_library_connections_url
      assert_not_requested :get, "https://libation.test/v1/accounts"
    end

    assert_response :success
    assert_select "#audible-sync-status[data-state='syncing']"
    assert_select "button[disabled]", text: "Syncing…"
    assert_select "button", text: "Check sync status", count: 0
  end

  test "connected account with no sync clearly presents the next step" do
    connection = create_connection

    VCR.turned_off do
      stub_request(:get, "https://libation.test/v1/accounts")
        .to_return(
          status: 200,
          body: { accounts: [ { account: "reader@example.com", locale: "us", authenticated: true } ] }.to_json
        )

      get admin_owned_library_connections_url
    end

    assert_response :success
    assert_select "#audible-sync-status[data-state='never_synced']", text: /One more step: sync your library/
    assert_select "button", text: "Sync library"
  end

  test "queued sync has persistent acknowledgement and disables another sync" do
    connection = create_connection
    connection.update!(sync_status: "queued", sync_started_at: Time.current)

    VCR.turned_off do
      get admin_owned_library_connections_url
      assert_not_requested :get, "https://libation.test/v1/accounts"
    end

    assert_response :success
    assert_select "#audible-sync-status[data-state='queued']", text: /page will update automatically/
    assert_select "button[disabled]", text: /Sync queued/
  end

  test "a stale queued sync exposes its recovery action" do
    connection = create_connection
    connection.update!(sync_status: "queued", sync_started_at: 2.minutes.ago)
    connection.update_column(:updated_at, 2.minutes.ago)

    VCR.turned_off do
      get admin_owned_library_connections_url
      assert_not_requested :get, "https://libation.test/v1/accounts"
    end

    assert_response :success
    assert_select "#audible-sync-status[data-state='queued']", text: /acknowledgement is stale/
    assert_select "button:not([disabled])", text: "Recover sync"
  end

  test "completed sync shows ownership counts and the main Library link" do
    connection = create_connection
    connection.update!(last_synced_at: 1.minute.ago)
    connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Purchased",
      ownership_type: "purchased"
    )
    connection.owned_library_items.create!(
      external_id: "B012345679",
      title: "Plus",
      ownership_type: "subscription"
    )

    OwnedLibraryBookMatcher.stub(:new, ->(*) { flunk "ordinary settings renders must not run exact backlog matching" }) do
      VCR.turned_off do
        stub_accounts(connection)
        get admin_owned_library_connections_url
      end
    end

    assert_response :success
    assert_select "#audible-sync-status[data-state='succeeded']", text: /1 purchased · 1 subscription/
    assert_select "a[href='#{library_index_path(anchor: 'library-catalog')}']", text: "Browse in Library"
  end

  test "first completed sync asks the administrator to confirm an existing-library backup" do
    connection = create_connection
    connection.update!(last_synced_at: 1.minute.ago)
    connection.owned_library_items.create!(
      external_id: "B012345670",
      title: "Existing Purchase",
      ownership_type: "purchased"
    )

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url
    end

    assert_response :success
    assert_select "#existing-library-backup-prompt" do
      assert_select "h2", text: "Back up your existing Audible library?"
      assert_select "form[action='#{backup_existing_admin_owned_library_connection_path(connection)}']"
      assert_select "input[name='confirm_existing_library_backup'][required]"
      assert_select "input[type='submit'][value='Queue eligible backups']"
      assert_select "form[action='#{dismiss_existing_backup_admin_owned_library_connection_path(connection)}']"
    end
  end

  test "existing-library backup requires the explicit confirmation control" do
    connection = create_connection
    connection.update!(last_synced_at: 1.minute.ago)
    connection.owned_library_items.create!(
      external_id: "B012345671",
      title: "Existing Purchase",
      ownership_type: "purchased"
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      post backup_existing_admin_owned_library_connection_url(connection)
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/explicitly confirmed/, flash[:alert])
    assert_not connection.reload.backlog_backup_decided?
  end

  test "confirmed existing-library backup creates a passive bounded queue" do
    connection = create_connection
    connection.update!(last_synced_at: 1.minute.ago)
    3.times do |index|
      connection.owned_library_items.create!(
        external_id: format("B01234567%d", index + 2),
        title: "Existing Purchase #{index}",
        ownership_type: "purchased"
      )
    end

    assert_difference -> { OwnedMediaImport.pending.count }, 3 do
      assert_enqueued_with(job: OwnedLibraryAutomationJob) do
        post backup_existing_admin_owned_library_connection_url(connection),
          params: { confirm_existing_library_backup: "1" },
          headers: { "HTTP_REFERER" => "http://[malformed" }
      end
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/3 existing Audible purchases/, flash[:notice])
    assert connection.reload.backlog_backup_decided?
    assert_equal 0, OwnedMediaImport.active.count
  end

  test "existing-library backup cannot start before the first sync" do
    connection = create_connection
    connection.owned_library_items.create!(
      external_id: "B012345675",
      title: "Unsynced Purchase",
      ownership_type: "purchased"
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      post backup_existing_admin_owned_library_connection_url(connection),
        params: { confirm_existing_library_backup: "1" }
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/Sync the Audible library/, flash[:alert])
  end

  test "dismissing the first-backup prompt keeps the action available under automation" do
    connection = create_connection
    connection.update!(last_synced_at: 1.minute.ago)
    connection.owned_library_items.create!(
      external_id: "B012345676",
      title: "Later Purchase",
      ownership_type: "purchased"
    )

    post dismiss_existing_backup_admin_owned_library_connection_url(connection),
      headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }

    assert_redirected_to admin_owned_library_connections_path(tab: "automation", anchor: "automation")
    assert connection.reload.backlog_backup_decided?

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url
    end
    assert_select "#existing-library-backup-prompt", count: 0
    assert_select "#audible-automation" do
      assert_select "form[action='#{backup_existing_admin_owned_library_connection_path(connection)}']"
      assert_select "input[value='Queue eligible backups']"
    end
  end

  test "failed sync stays visible and is retryable" do
    connection = create_connection
    connection.update!(
      sync_status: "failed",
      last_sync_error: "Audible sign-in expired",
      last_synced_at: 1.day.ago
    )

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url
    end

    assert_response :success
    assert_select "#audible-sync-status[data-state='failed'][role='alert'][aria-live='assertive']", text: /Audible sign-in expired/
    assert_select "button", text: "Retry sync"
  end

  test "a live unauthenticated account response overrides an old library snapshot" do
    connection = create_connection
    connection.update!(last_synced_at: 1.day.ago)
    connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Cached Purchase",
      ownership_type: "purchased"
    )

    VCR.turned_off do
      stub_accounts(connection, authenticated: false)
      get admin_owned_library_connections_url
    end

    assert_response :success
    assert_select "h2", text: "Audible account"
    assert_select "span", text: "Needs sign-in"
    assert_select "button[disabled]", text: "Connect Audible first"
  end

  test "already authenticated account returns success without a login URL" do
    connection = create_connection

    VCR.turned_off do
      stub_request(:post, "https://libation.test/v1/auth/start")
        .to_return(status: 200, body: { status: "authenticated" }.to_json)

      post auth_start_admin_owned_library_connection_url(connection),
        params: { account: "reader@example.com", locale: "us" }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "connection", anchor: "connection")
    assert_match(/already authenticated/, flash[:notice])
  end

  test "sync queues a background job" do
    connection = create_connection

    expected_args = lambda do |args|
      args.length == 4 && args.first == connection.id && args.second.present? &&
        args.third.nil? && args.fourth.present?
    end
    assert_enqueued_with(job: OwnedLibrarySyncJob, args: expected_args) do
      post sync_admin_owned_library_connection_url(connection),
        headers: { "HTTP_REFERER" => "http://[malformed" }
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    connection.reload
    assert connection.queued?
    assert connection.sync_started_at.present?
    assert_nil connection.last_sync_error
  end

  test "manual sync delegates its queue claim to the shared sync request service" do
    connection = create_connection
    expected_connection = connection
    called = false
    result = Struct.new(:status).new(:queued)
    request = lambda do |connection:, mode:|
      called = true
      assert_equal expected_connection, connection
      assert_equal :manual, mode
      result
    end

    OwnedLibrarySyncRequest.stub(:call, request) do
      post sync_admin_owned_library_connection_url(connection)
    end

    assert called
    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/sync queued/, flash[:notice])
  end

  test "automation controls show only supported intervals and explain the purchase baseline" do
    connection = create_connection
    connection.update!(last_synced_at: 1.hour.ago)

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url
    end

    assert_response :success
    assert_select "#audible-automation" do
      assert_select "form[action='#{automation_admin_owned_library_connection_path(connection)}']"
      assert_select "select[name='owned_library_connection[scheduled_sync_interval_minutes]'] option", count: 6
      assert_select "option[value='60']", text: "Every hour"
      assert_select "option[value='360']", text: "Every 6 hours"
      assert_select "option[value='720']", text: "Every 12 hours"
      assert_select "option[value='1440']", text: "Every 24 hours"
      assert_select "option[value='4320']", text: "Every 3 days"
      assert_select "option[value='10080']", text: "Weekly"
      assert_select "#automatic-backup-help", text: /Requires scheduled sync/
      assert_select "#automatic-backup-help", text: /later syncs/
      assert_select "input[name='owned_library_connection[automatic_backup_enabled]']:not([disabled])"
    end
  end

  test "automatic backup reports that scheduled sync is required" do
    connection = create_connection
    connection.update!(last_synced_at: 1.hour.ago)

    patch automation_admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        scheduled_sync_enabled: "0",
        scheduled_sync_interval_minutes: "1440",
        automatic_backup_enabled: "1"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "automation", anchor: "automation")
    assert_match(/require scheduled library sync/, flash[:alert])
    connection.reload
    assert_not connection.scheduled_sync_enabled?
    assert_not connection.automatic_backup_enabled?
  end

  test "automatic backup is unavailable until an initial sync establishes the baseline" do
    connection = create_connection

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url
    end

    assert_response :success
    assert_select "input[name='owned_library_connection[automatic_backup_enabled]'][disabled]"

    patch automation_admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        scheduled_sync_enabled: "1",
        scheduled_sync_interval_minutes: "1440",
        automatic_backup_enabled: "1"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "automation", anchor: "automation")
    assert_match(/initial library sync/, flash[:alert])
    connection.reload
    assert_not connection.scheduled_sync_enabled?
    assert_not connection.automatic_backup_enabled?
  end

  test "automation settings preserve token ciphertext and attribute future backups to the admin" do
    connection = create_connection
    connection.update!(last_synced_at: 1.hour.ago)
    bridge_token_ciphertext = connection.bridge_token_before_type_cast

    assert_no_enqueued_jobs only: OwnedMediaBackupJob do
      patch automation_admin_owned_library_connection_url(connection), params: {
        owned_library_connection: {
          scheduled_sync_enabled: "1",
          scheduled_sync_interval_minutes: "720",
          automatic_backup_enabled: "1",
          bridge_token: "replacement-must-not-be-permitted"
        }
      }, headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
    end

    assert_redirected_to admin_owned_library_connections_path(tab: "automation", anchor: "automation")
    assert_match(/no-download baseline/, flash[:notice])
    connection.reload
    assert connection.scheduled_sync_enabled?
    assert_equal 720, connection.scheduled_sync_interval_minutes
    assert connection.next_scheduled_sync_at.future?
    assert connection.automatic_backup_enabled?
    assert_equal users(:two), connection.automatic_backup_user
    assert connection.automatic_backup_enabled_at.present?
    assert_equal bridge_token_ciphertext, connection.bridge_token_before_type_cast
    assert_equal "token", connection.bridge_token
  end

  test "changing an interval preserves the eligible automatic backup owner" do
    connection = create_connection
    connection.update!(
      last_synced_at: 1.hour.ago,
      scheduled_sync_enabled: true,
      automatic_backup_enabled: true,
      automatic_backup_user: users(:two)
    )
    original_owner = connection.automatic_backup_user
    other_admin = User.create!(
      username: "automation_admin",
      name: "Automation Admin",
      password: "Password123!",
      role: :admin
    )
    sign_out
    sign_in_as(other_admin)

    patch automation_admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        scheduled_sync_enabled: "1",
        scheduled_sync_interval_minutes: "720",
        automatic_backup_enabled: "1"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "automation", anchor: "automation")
    assert_equal original_owner, connection.reload.automatic_backup_user
    assert_equal 720, connection.scheduled_sync_interval_minutes
  end

  test "disabling scheduled sync also disables automatic backup and resets its baseline" do
    connection = create_connection
    connection.update!(
      last_synced_at: 1.day.ago,
      scheduled_sync_enabled: true,
      scheduled_sync_interval_minutes: 360,
      automatic_backup_enabled: true,
      automatic_backup_enabled_at: 1.hour.ago,
      automatic_backup_user: users(:two)
    )

    patch automation_admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        scheduled_sync_enabled: "0",
        scheduled_sync_interval_minutes: "360",
        automatic_backup_enabled: "1"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "automation", anchor: "automation")
    assert_match(/automation disabled/, flash[:notice])
    connection.reload
    assert_not connection.scheduled_sync_enabled?
    assert_nil connection.next_scheduled_sync_at
    assert_not connection.automatic_backup_enabled?
    assert_nil connection.automatic_backup_enabled_at
    assert_nil connection.automatic_backup_user
  end

  test "automatic backup cannot be enabled during an in-flight library sync" do
    connection = create_connection
    connection.update!(
      last_synced_at: 1.day.ago,
      sync_status: "syncing",
      sync_job_id: "sync-active",
      sync_started_at: Time.current
    )

    patch automation_admin_owned_library_connection_url(connection), params: {
      owned_library_connection: {
        scheduled_sync_enabled: "1",
        scheduled_sync_interval_minutes: "1440",
        automatic_backup_enabled: "1"
      }
    }

    assert_redirected_to admin_owned_library_connections_path(tab: "automation", anchor: "automation")
    assert_match(/sync to finish/, flash[:alert])
    connection.reload
    assert_not connection.scheduled_sync_enabled?
    assert_not connection.automatic_backup_enabled?
  end

  test "automation status does not report an overdue deadline while a sync is active" do
    connection = create_connection
    connection.update!(
      last_synced_at: 1.day.ago,
      scheduled_sync_enabled: true,
      scheduled_sync_interval_minutes: 360,
      sync_status: "syncing",
      sync_job_id: "sync-active",
      sync_started_at: Time.current
    )
    connection.update_column(:next_scheduled_sync_at, 1.minute.ago)

    VCR.turned_off do
      get admin_owned_library_connections_url
      assert_not_requested :get, "https://libation.test/v1/accounts"
    end

    assert_response :success
    assert_select "#audible-automation", text: /sync is already in progress/
    assert_select "#audible-automation", text: /next sync is due/, count: 0
  end

  test "automation status warns when the attributed user is no longer an administrator" do
    connection = create_connection
    connection.update!(
      last_synced_at: 1.day.ago,
      scheduled_sync_enabled: true,
      automatic_backup_enabled: true,
      automatic_backup_user: users(:two)
    )
    connection.update_column(:automatic_backup_user_id, users(:one).id)

    VCR.turned_off do
      stub_accounts(connection)
      get admin_owned_library_connections_url
    end

    assert_response :success
    assert_select "#audible-automation", text: /Automatic backup is paused/
    assert_select "#audible-automation", text: /current administrator/
  end

  test "sync queues a recovery check when startup lost its companion job id" do
    connection = create_connection
    connection.update!(sync_status: "syncing", sync_job_id: nil, sync_started_at: 2.minutes.ago)
    connection.update_column(:updated_at, 2.minutes.ago)

    expected_args = lambda do |args|
      args.length == 4 && args.first == connection.id && args.second.present? &&
        args.third.nil? && args.fourth.present?
    end
    assert_enqueued_with(job: OwnedLibrarySyncJob, args: expected_args) do
      post sync_admin_owned_library_connection_url(connection)
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/recovery queued/, flash[:notice])
  end

  test "sync can resume polling an existing stale companion job" do
    connection = create_connection
    old_poll_token = "old-poll-chain"
    connection.update!(
      sync_status: "syncing",
      sync_job_id: connection.sync_job_state_value(
        job_id: "sync-existing",
        poll_token: old_poll_token
      ),
      sync_started_at: 2.minutes.ago
    )
    connection.update_column(:updated_at, 2.minutes.ago)
    token = connection.sync_started_at.utc.iso8601(6)

    assert_enqueued_with(
      job: OwnedLibrarySyncJob,
      args: lambda { |args|
        args.first(3) == [ connection.id, token, "sync-existing" ] &&
          args.fourth.present? && args.fourth != old_poll_token
      }
    ) do
      post sync_admin_owned_library_connection_url(connection)
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/status check queued/, flash[:notice])
    assert_equal "sync-existing", connection.reload.sync_job_id
    assert_not_equal old_poll_token, connection.sync_poll_token
  end

  test "sync can recover a stale queued acknowledgement" do
    connection = create_connection
    connection.update!(sync_status: "queued", sync_started_at: 2.minutes.ago)
    connection.update_column(:updated_at, 2.minutes.ago)

    expected_args = lambda do |args|
      args.length == 4 && args.first == connection.id && args.second.present? &&
        args.third.nil? && args.fourth.present?
    end
    assert_enqueued_with(job: OwnedLibrarySyncJob, args: expected_args) do
      post sync_admin_owned_library_connection_url(connection)
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/recovery queued/, flash[:notice])
    assert connection.reload.queued?
    assert connection.sync_started_at > 1.minute.ago
  end

  test "sync reports an enqueue failure as a durable failed state" do
    connection = create_connection

    OwnedLibrarySyncJob.stub(:perform_later, false) do
      post sync_admin_owned_library_connection_url(connection)
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/could not queue/, flash[:alert])
    assert connection.reload.failed?
    assert_equal "Shelfarr could not queue the Libation sync", connection.last_sync_error
  end

  test "a second click while sync is queued does not enqueue a duplicate" do
    connection = create_connection
    connection.update!(sync_status: "queued", sync_started_at: Time.current)

    assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
      post sync_admin_owned_library_connection_url(connection)
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/already queued or running/, flash[:notice])
    assert connection.reload.queued?
  end

  test "failed recovery enqueue releases a stranded syncing connection" do
    connection = create_connection
    connection.update!(sync_status: "syncing", sync_job_id: nil, sync_started_at: 2.minutes.ago)
    connection.update_column(:updated_at, 2.minutes.ago)

    OwnedLibrarySyncJob.stub(:perform_later, false) do
      post sync_admin_owned_library_connection_url(connection)
    end

    assert_redirected_to admin_owned_library_connections_path(anchor: "overview")
    assert_match(/could not queue/, flash[:alert])
    assert connection.reload.failed?
    assert_nil connection.sync_started_at
  end

  test "backup creates tracked import for an active title" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )

    assert_difference -> { OwnedMediaImport.count }, 1 do
      assert_enqueued_with(job: OwnedMediaBackupJob) do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id),
          headers: { "HTTP_REFERER" => "http://[malformed" }
      end
    end

    media_import = OwnedMediaImport.last
    assert_equal users(:two), media_import.requested_by
    assert_equal item, media_import.owned_library_item
    assert media_import.poll_token.present?
    assert_enqueued_with(
      job: OwnedMediaBackupJob,
      args: [ media_import.id, media_import.poll_token ]
    )
  end

  test "backup links an open matching request inside its acquisition transition" do
    connection = create_connection
    book = Book.create!(
      title: "Requested Audible Title",
      author: "Request Author",
      book_type: :audiobook
    )
    request = Request.create!(
      book: book,
      user: users(:one),
      status: :awaiting_purchase
    )
    item = connection.owned_library_items.create!(
      book: book,
      external_id: "B012345678",
      title: book.title,
      authors: [ book.author ],
      ownership_type: "purchased"
    )

    assert_difference -> { OwnedMediaImport.count }, 1 do
      assert_enqueued_with(job: OwnedMediaBackupJob) do
        post backup_item_admin_owned_library_connection_url(
          connection,
          item_id: item.id,
          request_id: request.id
        )
      end
    end

    assert_equal request, item.owned_media_imports.sole.request
  end

  test "backup refuses completed and failed request fulfillment" do
    connection = create_connection

    %i[completed failed].each_with_index do |status, index|
      book = Book.create!(
        title: "Closed Audible Request #{index}",
        author: "Request Author",
        book_type: :audiobook
      )
      request = Request.create!(book: book, user: users(:one), status: status)
      item = connection.owned_library_items.create!(
        book: book,
        external_id: format("B%09d", index),
        title: book.title,
        ownership_type: "purchased"
      )

      assert_no_difference -> { OwnedMediaImport.count } do
        assert_no_enqueued_jobs only: OwnedMediaBackupJob do
          post backup_item_admin_owned_library_connection_url(
            connection,
            item_id: item.id,
            request_id: request.id
          )
        end
      end

      assert_match(/no longer open/, flash[:alert])
    end
  end

  test "a cancellation committed immediately before backup admission wins the transition" do
    connection = create_connection
    book = Book.create!(
      title: "Cancellation Race Audible Title",
      author: "Request Author",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :awaiting_purchase)
    cancellation_request = Request.find(request.id)
    admission_request = Request.find(request.id)
    item = connection.owned_library_items.create!(
      book: book,
      external_id: "B087654321",
      title: book.title,
      ownership_type: "purchased"
    )
    acquire_after_cancellation = admission_request.method(:with_acquisition_transition_lock)
    transition = lambda do |&block|
      cancellation_request.cancel!
      acquire_after_cancellation.call(&block)
    end

    Request.stub(:find_by, admission_request) do
      admission_request.stub(:with_acquisition_transition_lock, transition) do
        assert_no_difference -> { OwnedMediaImport.count } do
          assert_no_enqueued_jobs only: OwnedMediaBackupJob do
            post backup_item_admin_owned_library_connection_url(
              connection,
              item_id: item.id,
              request_id: request.id
            )
          end
        end
      end
    end

    assert cancellation_request.reload.failed?
    assert_match(/no longer open/, flash[:alert])
  end

  test "backup from the main Library returns to the Library" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Library Title",
      ownership_type: "purchased"
    )

    post backup_item_admin_owned_library_connection_url(connection, item_id: item.id),
      headers: { "HTTP_REFERER" => library_index_url }

    assert_redirected_to library_index_url
    assert item.owned_media_imports.sole.queued?
  end

  test "an ambiguous local title requires and records the separate-edition choice" do
    connection = create_connection
    Book.create!(
      title: "A Shared Title",
      author: "A Shared Author",
      narrator: "A Shared Narrator",
      book_type: :audiobook,
      file_path: "/audiobooks/shared-title"
    )
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Shared Title",
      authors: [ "A Shared Author" ],
      narrators: [ "A Shared Narrator" ],
      ownership_type: "purchased"
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
    end
    assert_match(/could not confirm the identity safely/, flash[:alert])

    assert_difference -> { OwnedMediaImport.count }, 1 do
      assert_enqueued_with(job: OwnedMediaBackupJob) do
        post backup_item_admin_owned_library_connection_url(
          connection,
          item_id: item.id,
          separate_edition: "1"
        )
      end
    end
    assert item.owned_media_imports.sole.separate_edition?
  end

  test "distinct purchased titles can be queued independently" do
    connection = create_connection
    items = 3.times.map do |index|
      connection.owned_library_items.create!(
        external_id: format("B%09d", index),
        title: "Queue Title #{index}",
        ownership_type: "purchased"
      )
    end

    assert_difference -> { OwnedMediaImport.count }, 3 do
      items.each do |item|
        assert_enqueued_with(job: OwnedMediaBackupJob) do
          post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
        end
      end
    end

    assert items.all? { |item| item.owned_media_imports.sole.queued? }
  end

  test "a stale active backup can requeue its existing status check" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Recoverable Title",
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "queued",
      external_job_id: "backup-existing",
      updated_at: 3.minutes.ago
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      expected_args = lambda do |args|
        args.first == media_import.id && args.second.present?
      end
      assert_enqueued_with(job: OwnedMediaBackupJob, args: expected_args) do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
      end
    end

    assert_match(/status check/, flash[:notice])
    assert_not media_import.reload.recoverable?
  end

  test "a stale-looking backup does not supersede a still-running queue job" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Slow Backup",
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "downloading",
      external_job_id: "backup-live",
      poll_token: "live-poll-token",
      updated_at: 3.minutes.ago
    )

    OwnedLibraryAutomationJob.stub(:backup_job_pending?, true) do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
      end
    end

    assert_match(/already queued or running/, flash[:notice])
    assert_equal "live-poll-token", media_import.reload.poll_token
    assert media_import.downloading?
  end

  test "a failed backup with a retained destination retries the existing import" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Recoverable Publication",
      ownership_type: "purchased"
    )
    source = File.join(@audiobook_output_path, ".shelfarr-staging", "recoverable.m4b")
    destination = File.join(@audiobook_output_path, "Author", "Title", "book.m4b")
    FileUtils.mkdir_p(File.dirname(source))
    File.binwrite(source, "recoverable audio")
    upload = Upload.create!(
      user: users(:two),
      original_filename: "recoverable.m4b",
      file_path: source,
      file_size: File.size(source),
      status: :failed,
      error_message: "metadata reader failed"
    )
    stat = File.stat(source)
    media_import = item.owned_media_imports.create!(
      requested_by: users(:two),
      upload: upload,
      status: "failed",
      destination_path: destination,
      library_path: File.dirname(destination),
      staged_device: stat.dev,
      staged_inode: stat.ino,
      completed_at: Time.current
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_enqueued_with(
        job: OwnedMediaBackupJob,
        args: ->(args) { args.first == media_import.id && args.second.present? }
      ) do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
      end
    end

    assert_match(/status check/, flash[:notice])
    assert media_import.reload.processing?
    assert_nil media_import.completed_at
    assert upload.reload.pending?
  end

  test "a retained-destination retry restores failed state when enqueueing fails" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B087654321",
      title: "A Failed Recovery Enqueue",
      ownership_type: "purchased"
    )
    upload = Upload.create!(
      user: users(:two),
      original_filename: "recoverable.m4b",
      file_path: File.join(@audiobook_output_path, ".shelfarr-staging", "missing.m4b"),
      file_size: 10,
      status: :failed
    )
    media_import = item.owned_media_imports.create!(
      requested_by: users(:two),
      upload: upload,
      status: "failed",
      destination_path: File.join(@audiobook_output_path, "Author", "Title", "book.m4b"),
      library_path: File.join(@audiobook_output_path, "Author", "Title"),
      completed_at: Time.current
    )

    OwnedMediaBackupJob.stub(:perform_later, false) do
      post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
    end

    assert_match(/could not queue/, flash[:alert])
    assert media_import.reload.failed?
    assert upload.reload.failed?
  end

  test "a recent active backup does not enqueue a duplicate status check" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "An Active Title",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "queued",
      external_job_id: "backup-existing"
    )

    assert_no_enqueued_jobs only: OwnedMediaBackupJob do
      post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
    end

    assert_match(/already queued or running/, flash[:notice])
  end

  test "sync and backup claims wait for an active Audible sign-in" do
    connection = create_connection
    connection.update!(
      auth_session_id: "session-1",
      auth_login_url: "https://www.amazon.com/ap/signin?example=1",
      auth_expires_at: 10.minutes.from_now
    )
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )

    assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
      post sync_admin_owned_library_connection_url(connection)
    end
    assert_match(/Finish the current Audible sign-in/, flash[:alert])

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
      end
    end
    assert_match(/Finish the current Audible sign-in/, flash[:alert])
  end

  test "backup waits for an active library sync" do
    connection = create_connection
    connection.update!(sync_status: "syncing", sync_job_id: "sync-1", sync_started_at: Time.current)
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
      end
    end

    assert_match(/sync to finish/, flash[:alert])
  end

  test "library sync waits for active backups" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )
    item.owned_media_imports.create!(requested_by: users(:two), status: "queued")

    assert_no_enqueued_jobs only: OwnedLibrarySyncJob do
      post sync_admin_owned_library_connection_url(connection)
    end

    assert_match(/backups to finish/, flash[:alert])
    assert_equal "idle", connection.reload.sync_status
  end

  test "backup refuses a title that is not confirmed as purchased" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Plus Title",
      ownership_type: "subscription"
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
      end
    end

    assert_redirected_to admin_owned_library_connections_path
    assert_match(/confirmed as purchased/, flash[:alert])
  end

  test "backup refuses work while the connection is disabled" do
    connection = create_connection
    connection.update!(enabled: false)
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )

    assert_no_difference -> { OwnedMediaImport.count } do
      assert_no_enqueued_jobs only: OwnedMediaBackupJob do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
      end
    end

    assert_redirected_to admin_owned_library_connections_path
    assert_match(/Enable Audible Backup/, flash[:alert])
  end

  test "backup falls back safely for hostile referrers" do
    connection = create_connection
    connection.update!(enabled: false)
    item = connection.owned_library_items.create!(
      external_id: "B012345677",
      title: "Safe Backup Redirect",
      ownership_type: "purchased"
    )

    [ "https://attacker.example/phishing", "http://[malformed" ].each do |referer|
      post backup_item_admin_owned_library_connection_url(connection, item_id: item.id),
        headers: { "HTTP_REFERER" => referer }

      assert_redirected_to admin_owned_library_connections_path
    end
  end

  test "backup records a safe failure when queueing is unavailable" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )
    failed_job = Struct.new(:successfully_enqueued?).new(false)

    OwnedMediaBackupJob.stub(:perform_later, failed_job) do
      post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
    end

    assert_redirected_to admin_owned_library_connections_path
    assert_match(/could not queue/, flash[:alert])
    assert item.owned_media_imports.sole.failed?
  end

  test "backup records a safe failure when Active Job returns false" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345679",
      title: "Another Title",
      ownership_type: "purchased"
    )

    OwnedMediaBackupJob.stub(:perform_later, false) do
      post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
    end

    assert_redirected_to admin_owned_library_connections_path
    assert_match(/could not queue/, flash[:alert])
    assert item.owned_media_imports.sole.failed?
  end

  test "backup records a safe failure when enqueueing raises" do
    connection = create_connection
    item = connection.owned_library_items.create!(
      external_id: "B012345680",
      title: "A Third Title",
      ownership_type: "purchased"
    )

    enqueue_failure = ->(*) { raise ActiveJob::EnqueueError, "queue unavailable" }
    OwnedMediaBackupJob.stub(:perform_later, enqueue_failure) do
      post backup_item_admin_owned_library_connection_url(connection, item_id: item.id)
    end

    assert_redirected_to admin_owned_library_connections_path
    assert_match(/could not queue/, flash[:alert])
    assert item.owned_media_imports.sole.failed?
  end

  test "non admin cannot access Audible Backup" do
    sign_in_as(users(:one))

    get admin_owned_library_connections_url

    assert_redirected_to root_path
  end

  private

  def create_connection
    OwnedLibraryConnection.create!(
      url: "https://libation.test",
      allow_private_network: false,
      bridge_token: "token",
      enabled: true
    )
  end

  def stub_accounts(connection, authenticated: true)
    stub_request(:get, "#{connection.url}/v1/accounts")
      .to_return(
        status: 200,
        body: {
          accounts: [
            { account: "reader@example.com", locale: "us", authenticated: authenticated }
          ]
        }.to_json
      )
  end
end
