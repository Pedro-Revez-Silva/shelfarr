# frozen_string_literal: true

require "application_system_test_case"

class SetupWizardTest < ApplicationSystemTestCase
  setup do
    @admin = users(:two)
    DownloadClient.delete_all
    Setting.where(key: %w[
      setup_wizard_completed indexer_provider prowlarr_url prowlarr_api_key
      library_platform audiobookshelf_url audiobookshelf_api_key
      audiobookshelf_audiobook_library_id audiobookshelf_ebook_library_id
      audiobook_output_path ebook_output_path download_local_path download_remote_path
      immediate_search_enabled auto_select_enabled
    ]).delete_all
    reset_client_caches
  end

  # The wizard warms process-wide client connections that outlive the rolled-back settings.
  teardown do
    reset_client_caches
  end

  test "admin connects prowlarr, qbittorrent, and audiobookshelf" do
    stub_request(:get, "http://prowlarr:9696/api/v1/indexer")
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
    stub_qbittorrent_connection("http://qbittorrent:8080")
    stub_request(:get, "http://audiobookshelf:13378/api/libraries").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        "libraries" => [
          { "id" => "lib-audio", "name" => "Audiobooks", "mediaType" => "book", "folders" => [ { "fullPath" => "/audiobooks" } ] },
          { "id" => "lib-ebooks", "name" => "Ebooks", "mediaType" => "book", "folders" => [ { "fullPath" => "/ebooks" } ] }
        ]
      }.to_json
    )

    sign_in_as(@admin)
    visit admin_setup_wizard_path

    assert_text "Set up Shelfarr"
    fill_in "Prowlarr URL", with: "http://prowlarr:9696"
    fill_in "Prowlarr API key", with: "prowlarr-key"
    click_button "Test and continue"

    assert_text "qBittorrent"
    fill_in "qBittorrent URL", with: "http://qbittorrent:8080"
    fill_in "Username", with: "admin"
    fill_in "Password", with: "secret"
    click_button "Test and continue"

    assert_text "Audiobook folder"
    fill_in "Audiobook folder", with: "/audiobooks"
    fill_in "Ebook folder", with: "/ebooks"
    fill_in "Download folder in this container", with: "/downloads"
    fill_in "qBittorrent's path for the same folder (optional)", with: ""
    click_button "Save and continue"

    assert_text "Audiobookshelf URL"
    fill_in "Audiobookshelf URL", with: "http://audiobookshelf:13378"
    fill_in "Audiobookshelf API token", with: "abs-token"
    click_button "Test and continue"

    assert_text "Choose the libraries Shelfarr should scan."
    assert_equal "lib-audio", find_field("Audiobook library").value
    select "Ebooks", from: "Ebook library"
    click_button "Save and continue"

    assert_text "90 out of 100"
    click_button "Finish"

    assert_current_path root_path
    assert_equal "prowlarr", SettingsService.get(:indexer_provider)
    assert_equal "prowlarr-key", SettingsService.get(:prowlarr_api_key)
    assert_equal "abs-token", SettingsService.get(:audiobookshelf_api_key)
    assert_equal "lib-audio", SettingsService.get(:audiobookshelf_audiobook_library_id)
    assert_equal "lib-ebooks", SettingsService.get(:audiobookshelf_ebook_library_id)
    assert_equal true, SettingsService.get(:immediate_search_enabled)
    assert_equal false, SettingsService.get(:auto_select_enabled)
    assert_equal true, SettingsService.get(:setup_wizard_completed)

    client = DownloadClient.qbittorrent.sole
    assert_equal "http://qbittorrent:8080", client.url
    assert_equal "", client.category
    assert_nil client.download_path
    assert_not_requested :post, "http://qbittorrent:8080/api/v2/torrents/createCategory"

    click_button "Setup"
    assert_text "Prowlarr URL"
    assert_equal false, SettingsService.get(:setup_wizard_completed)
  end

  private

  def reset_client_caches
    LibraryPlatformClient.reset_connections!
    IndexerClient.reset_all_connections!
    Thread.current[:qbittorrent_sessions] = {}
  end
end
