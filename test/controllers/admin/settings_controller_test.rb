# frozen_string_literal: true

require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
    AudiobookshelfClient.reset_connection!
    ProwlarrClient.reset_connection!
    FlaresolverrClient.reset_connection!
  end

  teardown do
    AudiobookshelfClient.reset_connection!
    ProwlarrClient.reset_connection!
    FlaresolverrClient.reset_connection!
  end

  test "index requires admin" do
    sign_out
    get admin_settings_url
    assert_response :redirect
  end

  test "index shows settings page" do
    get admin_settings_url
    assert_response :success
    assert_select "h1", "Settings"
  end

  test "index shows library picker dropdown when audiobookshelf configured" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "libraries" => [
              { "id" => "lib-audio", "name" => "Audiobooks", "mediaType" => "book", "folders" => [] },
              { "id" => "lib-ebook", "name" => "Ebooks", "mediaType" => "book", "folders" => [] }
            ]
          }.to_json
        )

      get admin_settings_url
      assert_response :success

      # Check that library options appear in the page
      assert_select "select[name='settings[audiobookshelf_audiobook_library_id]']" do
        assert_select "option[value='lib-audio']", text: "Audiobooks (book)"
        assert_select "option[value='lib-ebook']", text: "Ebooks (book)"
      end
    end
  end

  test "index shows text input when audiobookshelf not configured" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobookshelf_api_key, "")

    get admin_settings_url
    assert_response :success

    # Should show text input instead of select
    assert_select "input[name='settings[audiobookshelf_audiobook_library_id]']"
  end

  test "index handles audiobookshelf api errors gracefully" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_return(status: 500)

      # Should not raise, should show text input as fallback
      get admin_settings_url
      assert_response :success
      assert_select "input[name='settings[audiobookshelf_audiobook_library_id]']"
    end
  end

  test "bulk_update updates multiple settings" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        max_retries: "20",
        rate_limit_delay: "5"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal 20, SettingsService.get(:max_retries)
    assert_equal 5, SettingsService.get(:rate_limit_delay)
  end

  test "bulk_update validates path templates" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        audiobook_path_template: "{invalid_var}"
      }
    }

    assert_redirected_to admin_settings_path
    assert flash[:alert].present?
  end

  # Test connection tests for Prowlarr
  test "test_prowlarr fails when not configured" do
    SettingsService.set(:prowlarr_url, "")
    SettingsService.set(:prowlarr_api_key, "")

    post test_prowlarr_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_prowlarr succeeds when connection works" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/health")
        .with(headers: { "X-Api-Key" => "test-api-key" })
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      post test_prowlarr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successful/i, flash[:notice]
    end
  end

  test "test_prowlarr fails when connection fails" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/health")
        .with(headers: { "X-Api-Key" => "test-api-key" })
        .to_return(status: 401)

      post test_prowlarr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_prowlarr handles connection errors" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/health")
        .to_timeout

      post test_prowlarr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  # Test connection tests for Audiobookshelf
  test "test_audiobookshelf fails when not configured" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobookshelf_api_key, "")

    post test_audiobookshelf_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_audiobookshelf succeeds when connection works" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(
          status: 200,
          body: { "libraries" => [{ "id" => "lib1", "name" => "Test" }] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post test_audiobookshelf_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successful/i, flash[:notice]
    end
  end

  test "test_audiobookshelf fails when connection fails" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(status: 401)

      post test_audiobookshelf_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_audiobookshelf handles connection errors" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_timeout

      post test_audiobookshelf_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  # Test connection tests for OIDC
  test "test_oidc fails when not enabled" do
    SettingsService.set(:oidc_enabled, false)

    post test_oidc_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not enabled/i, flash[:alert]
  end

  test "test_oidc fails when issuer not configured" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "")

    post test_oidc_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_oidc succeeds when discovery document valid" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            issuer: "https://auth.example.com",
            authorization_endpoint: "https://auth.example.com/authorize",
            token_endpoint: "https://auth.example.com/token"
          }.to_json
        )

      post test_oidc_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /valid/i, flash[:notice]
    end
  end

  test "test_oidc fails when discovery document invalid" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_return(status: 404)

      post test_oidc_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_oidc handles connection errors" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_timeout

      post test_oidc_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  # Turbo Stream response tests
  test "bulk_update returns turbo stream when requested" do
    patch bulk_update_admin_settings_url,
      params: { settings: { max_retries: "25" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match "settings-form", response.body
    assert_equal 25, SettingsService.get(:max_retries)
  end

  test "bulk_update turbo stream shows error on validation failure" do
    patch bulk_update_admin_settings_url,
      params: { settings: { audiobook_path_template: "{invalid_var}" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match "flash", response.body
  end

  test "test_prowlarr returns turbo stream when requested" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/health")
        .with(headers: { "X-Api-Key" => "test-api-key" })
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      post test_prowlarr_admin_settings_url,
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_match "turbo-stream", response.body
    end
  end

  test "test_audiobookshelf returns turbo stream when requested" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(
          status: 200,
          body: { "libraries" => [{ "id" => "lib1", "name" => "Test" }] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post test_audiobookshelf_admin_settings_url,
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_match "turbo-stream", response.body
    end
  end

  # SSL error handling tests
  test "test_prowlarr handles SSL errors" do
    SettingsService.set(:prowlarr_url, "https://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "https://localhost:9696/api/v1/health")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      post test_prowlarr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_audiobookshelf handles SSL errors" do
    SettingsService.set(:audiobookshelf_url, "https://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "https://localhost:13378/api/libraries")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      post test_audiobookshelf_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_oidc handles SSL errors" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      post test_oidc_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  # Connection cache reset tests
  test "bulk_update uses new audiobookshelf url after settings change" do
    SettingsService.set(:audiobookshelf_url, "http://old.example.com")
    SettingsService.set(:audiobookshelf_api_key, "test-key")

    VCR.turned_off do
      # The controller should use the NEW url after updating settings
      # This verifies the connection was reset and recreated with new credentials
      stub_request(:get, "http://new.example.com/api/libraries")
        .to_return(status: 200, body: { "libraries" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      patch bulk_update_admin_settings_url, params: {
        settings: { audiobookshelf_url: "http://new.example.com" }
      }

      assert_response :redirect
      assert_equal "http://new.example.com", SettingsService.get(:audiobookshelf_url)
      # If reset didn't work, it would have tried old.example.com and failed
      assert_requested(:get, "http://new.example.com/api/libraries")
    end
  end

  test "bulk_update resets prowlarr connection when api key changes" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "old-key")

    # Prime the connection with old credentials
    ProwlarrClient.send(:connection)
    old_connection = ProwlarrClient.instance_variable_get(:@connection)
    assert_not_nil old_connection

    patch bulk_update_admin_settings_url, params: {
      settings: { prowlarr_api_key: "new-key" }
    }

    # Connection should be reset - either nil or a different object
    new_connection = ProwlarrClient.instance_variable_get(:@connection)
    assert_nil new_connection, "Connection should be reset after prowlarr settings change"
  end

  # Test connection tests for FlareSolverr
  test "test_flaresolverr fails when not configured" do
    SettingsService.set(:flaresolverr_url, "")

    post test_flaresolverr_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_flaresolverr succeeds when connection works" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_return(
          status: 200,
          body: {
            status: "ok",
            message: "",
            solution: { status: 200, response: "<html></html>" }
          }.to_json
        )

      post test_flaresolverr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successful/i, flash[:notice]
    end

    FlaresolverrClient.reset_connection!
    SettingsService.set(:flaresolverr_url, "")
  end

  test "test_flaresolverr fails when connection fails" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_return(
          status: 200,
          body: { status: "error", message: "Challenge failed" }.to_json
        )

      post test_flaresolverr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end

    FlaresolverrClient.reset_connection!
    SettingsService.set(:flaresolverr_url, "")
  end

  test "test_flaresolverr handles connection errors" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      post test_flaresolverr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end

    FlaresolverrClient.reset_connection!
    SettingsService.set(:flaresolverr_url, "")
  end

  test "test_flaresolverr returns turbo stream when requested" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_return(
          status: 200,
          body: {
            status: "ok",
            message: "",
            solution: { status: 200, response: "<html></html>" }
          }.to_json
        )

      post test_flaresolverr_admin_settings_url,
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_match "turbo-stream", response.body
    end

    FlaresolverrClient.reset_connection!
    SettingsService.set(:flaresolverr_url, "")
  end

  test "bulk_update resets flaresolverr connection when url changes" do
    SettingsService.set(:flaresolverr_url, "http://old.example.com:8191")

    # Prime the connection with old url
    FlaresolverrClient.send(:connection)
    old_connection = FlaresolverrClient.instance_variable_get(:@connection)
    assert_not_nil old_connection

    patch bulk_update_admin_settings_url, params: {
      settings: { flaresolverr_url: "http://new.example.com:8191" }
    }

    # Connection should be reset
    new_connection = FlaresolverrClient.instance_variable_get(:@connection)
    assert_nil new_connection, "Connection should be reset after flaresolverr settings change"

    SettingsService.set(:flaresolverr_url, "")
  end
end
