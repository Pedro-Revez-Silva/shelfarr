# frozen_string_literal: true

require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
    AudiobookshelfClient.reset_connection!
  end

  teardown do
    AudiobookshelfClient.reset_connection!
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
end
