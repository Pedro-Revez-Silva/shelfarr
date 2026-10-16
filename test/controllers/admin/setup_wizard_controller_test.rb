# frozen_string_literal: true

require "test_helper"

class Admin::SetupWizardControllerTest < ActionDispatch::IntegrationTest
  QBITTORRENT_API_KEY = "qbt_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    @admin = users(:two)
    sign_in_as(@admin)
    reset_client_caches
    Setting.where(key: %w[
      setup_wizard_completed indexer_provider prowlarr_url prowlarr_api_key
      library_platform audiobookshelf_url audiobookshelf_api_key
      audiobookshelf_audiobook_library_id audiobookshelf_ebook_library_id
      audiobook_output_path ebook_output_path download_local_path download_remote_path
      immediate_search_enabled auto_select_enabled auto_select_confidence_threshold auto_select_min_seeders
    ]).delete_all
    DownloadClient.delete_all
  end

  # The wizard warms process-wide client connections that outlive the rolled-back settings.
  teardown do
    reset_client_caches
  end

  test "non admin cannot open the wizard" do
    sign_out
    sign_in_as(users(:one))

    get admin_setup_wizard_url

    assert_redirected_to root_path
  end

  test "show starts on prowlarr and the header can rerun setup" do
    get admin_setup_wizard_url

    assert_response :success
    assert_select "h1", "Set up Shelfarr"
    assert_select "h2", "Prowlarr"
    assert_select "button", "Skip this step"
    assert_select "button", "Skip setup"
    assert_select "form[action='#{restart_admin_setup_wizard_path}'] button", "Setup"
  end

  test "wizard stays available when an indexer and download client already exist" do
    SettingsService.set(:setup_wizard_completed, true)
    SettingsService.set(:indexer_provider, "prowlarr")
    SettingsService.set(:prowlarr_url, "http://prowlarr:9696")
    SettingsService.set(:prowlarr_api_key, "saved-key")
    DownloadClient.create!(name: "Existing", client_type: "qbittorrent", url: "http://qbittorrent:8080", username: "admin", password: "secret", enabled: true)

    assert_not SetupWizard.pending?

    post restart_admin_setup_wizard_url

    assert_redirected_to admin_setup_wizard_path
    assert_equal false, SettingsService.get(:setup_wizard_completed)
    follow_redirect!
    assert_response :success
    assert_select "h2", "Prowlarr"
  end

  test "prowlarr continue saves the indexer and a loopback refusal does not" do
    VCR.turned_off do
      stub_request(:get, "http://prowlarr:9696/api/v1/indexer").to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      patch admin_setup_wizard_url(step: "prowlarr"), params: { wizard: { url: "http://prowlarr:9696", api_key: "prowlarr-key" } }

      assert_redirected_to admin_setup_wizard_path(step: "qbittorrent")
      assert_equal "prowlarr", SettingsService.get(:indexer_provider)
      assert_equal "http://prowlarr:9696", SettingsService.get(:prowlarr_url)
      assert_equal "prowlarr-key", SettingsService.get(:prowlarr_api_key)
    end

    VCR.turned_off do
      Setting.where(key: %w[indexer_provider prowlarr_url prowlarr_api_key]).delete_all
      stub_request(:get, "http://127.0.0.1:9696/api/v1/indexer")
        .to_raise(Errno::ECONNREFUSED.new("Connection refused - connect(2)"))

      patch admin_setup_wizard_url(step: "prowlarr"), params: { wizard: { url: "http://127.0.0.1:9696", api_key: "typed-key" } }

      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: "Could not connect to Prowlarr: Connection refused. #{ConnectionErrorClassifier::LOCALHOST_HINT}"
      assert_not SettingsService.active_indexer_configured?
    end
  end

  test "skip this step leaves prowlarr unset and skip setup completes the wizard" do
    post skip_admin_setup_wizard_url(step: "prowlarr")

    assert_redirected_to admin_setup_wizard_path(step: "qbittorrent")
    assert_not SettingsService.active_indexer_configured?
    assert_equal false, SettingsService.get(:setup_wizard_completed)

    post skip_admin_setup_wizard_url(exit: "1")

    assert_redirected_to root_path
    assert_equal true, SettingsService.get(:setup_wizard_completed)
  end

  test "qbittorrent continue creates one blank-category client and a rerun updates it" do
    VCR.turned_off do
      stub_qbittorrent_connection("http://qbittorrent:8080")
      stub_qbittorrent_connection("http://qbittorrent:9090")

      assert_difference "DownloadClient.count", 1 do
        patch admin_setup_wizard_url(step: "qbittorrent"), params: {
          wizard: { url: "http://qbittorrent:8080", username: "admin", password: "secret", category: "" }
        }
      end

      client = DownloadClient.qbittorrent.sole
      assert_redirected_to admin_setup_wizard_path(step: "folders")
      assert client.enabled?
      assert_equal "", client.category
      assert_nil client.download_path
      assert_not_requested :post, "http://qbittorrent:8080/api/v2/torrents/createCategory"

      assert_no_difference "DownloadClient.count" do
        patch admin_setup_wizard_url(step: "qbittorrent"), params: {
          wizard: { url: "http://qbittorrent:9090", username: "admin", password: "", category: "" }
        }
      end

      assert_equal "http://qbittorrent:9090", client.reload.url
      assert_equal "secret", client.password
    end
  end

  test "qbittorrent continue rejects a malformed api key without creating a client" do
    assert_no_difference "DownloadClient.count" do
      patch admin_setup_wizard_url(step: "qbittorrent"), params: {
        wizard: { url: "http://qbittorrent:8080", api_key: "not-a-key", category: "" }
      }
    end

    assert_response :unprocessable_entity
    assert_match "qbt_", response.body
  end

  test "folders save a remote path only when qBittorrent is outside the container and warnings do not block" do
    client = DownloadClient.create!(name: "qBittorrent", client_type: "qbittorrent", url: "http://qbittorrent:8080", username: "admin", password: "secret", category: "", enabled: true)
    Dir.mktmpdir do |local_path|
      VCR.turned_off do
        stub_qbittorrent_connection("http://qbittorrent:8080")
        stub_request(:get, "http://qbittorrent:8080/api/v2/app/preferences")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { "save_path" => "/mnt/torrents" }.to_json)

        patch admin_setup_wizard_url(step: "folders"), params: {
          wizard: {
            audiobook_output_path: "#{local_path}/audiobooks",
            ebook_output_path: "#{local_path}/ebooks",
            download_local_path: local_path,
            download_remote_path: ""
          }
        }

        assert_redirected_to admin_setup_wizard_path(step: "audiobookshelf")
        assert_equal "qBittorrent saves to /mnt/torrents, which is not inside #{local_path} or does not exist in this container.", flash[:alert]
        assert_equal "", SettingsService.get(:download_remote_path)
        assert_equal local_path, SettingsService.get(:download_local_path)
        assert_nil client.reload.download_path

        patch admin_setup_wizard_url(step: "folders"), params: {
          wizard: {
            audiobook_output_path: "#{local_path}/audiobooks",
            ebook_output_path: "#{local_path}/ebooks",
            download_local_path: local_path,
            download_remote_path: "/mnt/torrents"
          }
        }

        assert_equal "/mnt/torrents", SettingsService.get(:download_remote_path)
        follow_redirect!
        assert_response :success
        refute_match "qBittorrent save path", response.body

        stub_request(:get, "http://qbittorrent:8080/api/v2/app/preferences")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { "save_path" => local_path }.to_json)

        patch admin_setup_wizard_url(step: "folders"), params: {
          wizard: {
            audiobook_output_path: "#{local_path}/audiobooks",
            ebook_output_path: "#{local_path}/ebooks",
            download_local_path: local_path,
            download_remote_path: "/mnt/torrents"
          }
        }

        assert_equal "", SettingsService.get(:download_remote_path)

        patch admin_setup_wizard_url(step: "folders"), params: {
          wizard: {
            audiobook_output_path: "#{local_path}/audiobooks",
            ebook_output_path: "#{local_path}/ebooks",
            download_local_path: "#{local_path}/",
            download_remote_path: "/mnt/torrents"
          }
        }

        assert_equal "", SettingsService.get(:download_remote_path)
        assert_equal local_path, SettingsService.get(:download_local_path)
      end
    end
  end

  test "audiobookshelf continue saves the token and then the chosen libraries" do
    VCR.turned_off do
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

      patch admin_setup_wizard_url(step: "audiobookshelf"), params: {
        wizard: { url: "http://audiobookshelf:13378", api_key: "abs-token" }
      }

      assert_redirected_to admin_setup_wizard_path(step: "audiobookshelf")
      assert_equal "audiobookshelf", SettingsService.get(:library_platform)
      assert_equal "http://audiobookshelf:13378", SettingsService.get(:audiobookshelf_url)
      assert_equal "abs-token", SettingsService.get(:audiobookshelf_api_key)

      follow_redirect!
      assert_select "option[value='lib-audio']", text: "Audiobooks"
      assert_select "option[value='lib-ebooks']", text: "Ebooks"

      patch admin_setup_wizard_url(step: "audiobookshelf"), params: {
        wizard: { phase: "libraries", audiobook_library_id: "lib-audio", ebook_library_id: "lib-ebooks" }
      }

      assert_redirected_to admin_setup_wizard_path(step: "search")
      assert_equal "lib-audio", SettingsService.get(:audiobookshelf_audiobook_library_id)
      assert_equal "lib-ebooks", SettingsService.get(:audiobookshelf_ebook_library_id)
    end
  end

  test "finish turns immediate search on, leaves auto select off, and explains the score" do
    get admin_setup_wizard_url(step: "search")

    assert_response :success
    assert_match "at least 90 out of 100 and have at least 1 seeder", response.body
    assert_select "input[name='wizard[immediate_search_enabled]'][value='1'][checked]"
    assert_select "input[name='wizard[auto_select_enabled]'][value='1']:not([checked])"

    patch admin_setup_wizard_url(step: "search"), params: {
      wizard: { immediate_search_enabled: "1", auto_select_enabled: "0" }
    }

    assert_redirected_to root_path
    assert_equal true, SettingsService.get(:immediate_search_enabled)
    assert_equal false, SettingsService.get(:auto_select_enabled)
    assert_equal true, SettingsService.get(:setup_wizard_completed)
  end

  test "turning auto select on uses the default score and seeder minimum" do
    patch admin_setup_wizard_url(step: "search"), params: {
      wizard: { immediate_search_enabled: "1", auto_select_enabled: "1" }
    }

    assert_equal true, SettingsService.get(:auto_select_enabled)
    assert_equal 90, SettingsService.get(:auto_select_confidence_threshold)
    assert_equal 1, SettingsService.get(:auto_select_min_seeders)
    assert_equal true, SettingsService.get(:setup_wizard_completed)
  end

  test "a rerun keeps and shows an existing auto select policy" do
    SettingsService.set(:auto_select_confidence_threshold, 100)
    SettingsService.set(:auto_select_min_seeders, 10)

    get admin_setup_wizard_url(step: "search")
    assert_match "at least 100 out of 100 and have at least 10 seeders", response.body

    patch admin_setup_wizard_url(step: "search"), params: {
      wizard: { immediate_search_enabled: "1", auto_select_enabled: "1" }
    }

    assert_equal 100, SettingsService.get(:auto_select_confidence_threshold)
    assert_equal 10, SettingsService.get(:auto_select_min_seeders)
  end

  test "search does not warn about qBittorrent paths for a client with its own download path" do
    DownloadClient.create!(name: "qBittorrent", client_type: "qbittorrent", url: "http://qbittorrent:8080", username: "admin", password: "secret", category: "", download_path: "/mnt/torrents", enabled: true)
    Dir.mktmpdir do |local_path|
      SettingsService.set(:download_local_path, local_path)
      VCR.turned_off do
        stub_qbittorrent_connection("http://qbittorrent:8080")
        stub_request(:get, "http://qbittorrent:8080/api/v2/app/preferences")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { "save_path" => "/mnt/torrents" }.to_json)

        get admin_setup_wizard_url(step: "search")

        assert_select "[role=status]", count: 0
      end
    end
  end

  test "a fresh install still needs the wizard until setup is finished" do
    assert SetupWizard.pending?

    SettingsService.set(:setup_wizard_completed, true)

    assert_not SetupWizard.pending?
  end

  test "steps link to each other and a rerun keeps the saved prowlarr key" do
    SettingsService.set(:indexer_provider, "prowlarr")
    SettingsService.set(:prowlarr_url, "http://prowlarr:9696")
    SettingsService.set(:prowlarr_api_key, "saved-key")

    get admin_setup_wizard_url(step: "qbittorrent")

    assert_select "nav[aria-label='Setup steps'] a[aria-current='step']", "2. qBittorrent"
    assert_select "nav[aria-label='Setup steps'] a[href=?]", admin_setup_wizard_path(step: "folders"), text: "3. Folders"
    assert_select "a[href=?]", admin_setup_wizard_path(step: "prowlarr"), text: "Back"

    get admin_setup_wizard_url(step: "prowlarr")
    assert_select "input[name='wizard[api_key]'][placeholder='Saved. Leave blank to keep it.']"

    VCR.turned_off do
      stub_request(:get, "http://prowlarr:9696/api/v1/indexer")
        .with(headers: { "X-Api-Key" => "saved-key" })
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      patch admin_setup_wizard_url(step: "prowlarr"), params: { wizard: { url: "http://prowlarr:9696", api_key: "" } }

      assert_redirected_to admin_setup_wizard_path(step: "qbittorrent")
      assert_equal "saved-key", SettingsService.get(:prowlarr_api_key)
    end
  end

  test "prowlarr names a rejected api key" do
    VCR.turned_off do
      stub_request(:get, "http://prowlarr:9696/api/v1/indexer").to_return(status: 401, body: "{}", headers: { "Content-Type" => "application/json" })

      patch admin_setup_wizard_url(step: "prowlarr"), params: { wizard: { url: "http://prowlarr:9696", api_key: "wrong" } }

      assert_response :unprocessable_entity
      assert_select "[role=alert]", "Prowlarr rejected the API key. Copy it from Prowlarr under Settings > General."
      assert_not SettingsService.active_indexer_configured?
    end
  end

  test "qbittorrent continue starts the download monitor" do
    VCR.turned_off do
      stub_qbittorrent_connection("http://qbittorrent:8080")

      assert_enqueued_with(job: DownloadMonitorJob) do
        patch admin_setup_wizard_url(step: "qbittorrent"), params: {
          wizard: { url: "http://qbittorrent:8080", username: "admin", password: "secret", category: "" }
        }
      end
    end
  end

  test "a qbittorrent rerun keeps the client download path and a new password replaces an api key" do
    client = DownloadClient.create!(
      name: "qBittorrent", client_type: "qbittorrent", url: "http://qbittorrent:8080",
      api_key: QBITTORRENT_API_KEY, category: "", download_path: "/mnt/torrents", enabled: true
    )

    VCR.turned_off do
      stub_qbittorrent_connection("http://qbittorrent:8080")

      patch admin_setup_wizard_url(step: "qbittorrent"), params: {
        wizard: { url: "http://qbittorrent:8080", username: "admin", password: "secret", api_key: "", category: "" }
      }

      assert_redirected_to admin_setup_wizard_path(step: "folders")
      assert_requested :post, "http://qbittorrent:8080/api/v2/auth/login", body: hash_including("username" => "admin", "password" => "secret")
    end

    client.reload
    assert_nil client.api_key
    assert_equal "secret", client.password
    assert_equal "/mnt/torrents", client.download_path
  end

  test "folders do not map a category path that is already inside the download folder" do
    DownloadClient.create!(name: "qBittorrent", client_type: "qbittorrent", url: "http://qbittorrent:8080", username: "admin", password: "secret", category: "books", enabled: true)
    Dir.mktmpdir do |local_path|
      SettingsService.set(:download_local_path, local_path)
      VCR.turned_off do
        stub_qbittorrent_connection("http://qbittorrent:8080")
        stub_request(:get, "http://qbittorrent:8080/api/v2/app/preferences")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { "save_path" => local_path }.to_json)
        stub_request(:get, "http://qbittorrent:8080/api/v2/torrents/categories")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { "books" => { "savePath" => "#{local_path}/books" } }.to_json)

        get admin_setup_wizard_url(step: "folders")
        assert_select "input[name='wizard[download_remote_path]']" do |inputs|
          assert_equal "", inputs.first["value"].to_s
        end

        patch admin_setup_wizard_url(step: "folders"), params: {
          wizard: { audiobook_output_path: "/audiobooks", ebook_output_path: "/ebooks", download_local_path: local_path, download_remote_path: "#{local_path}/books" }
        }

        assert_equal "", SettingsService.get(:download_remote_path)
      end
    end
  end

  test "folders suggest the qBittorrent save path and check the suggestion before it is saved" do
    DownloadClient.create!(name: "qBittorrent", client_type: "qbittorrent", url: "http://qbittorrent:8080", username: "admin", password: "secret", category: "", enabled: true)
    Dir.mktmpdir do |local_path|
      SettingsService.set(:download_local_path, local_path)
      VCR.turned_off do
        stub_qbittorrent_connection("http://qbittorrent:8080")
        stub_request(:get, "http://qbittorrent:8080/api/v2/app/preferences")
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { "save_path" => "/mnt/torrents" }.to_json)

        get admin_setup_wizard_url(step: "folders")

        assert_select "input[name='wizard[download_remote_path]'][value='/mnt/torrents']"
        assert_select "[role=status]", count: 0
      end
    end
  end

  test "audiobookshelf with no libraries is not saved and says what to do" do
    VCR.turned_off do
      stub_request(:get, "http://audiobookshelf:13378/api/libraries")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { "libraries" => [] }.to_json)

      patch admin_setup_wizard_url(step: "audiobookshelf"), params: { wizard: { url: "http://audiobookshelf:13378", api_key: "abs-token" } }

      assert_response :unprocessable_entity
      assert_select "[role=alert]", /has no libraries yet/
      assert_not SettingsService.configured?(:audiobookshelf_api_key)
    end
  end

  test "a connected audiobookshelf step leads with one library form and preselects the matching folder once" do
    SettingsService.set(:audiobook_output_path, "/audiobooks/Shelfarr")
    SettingsService.set(:ebook_output_path, "/books")

    VCR.turned_off do
      stub_request(:get, "http://audiobookshelf:13378/api/libraries").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "libraries" => [
          { "id" => "lib-audio", "name" => "Audiobooks", "mediaType" => "book", "folders" => [ { "fullPath" => "/audiobooks" } ] },
          { "id" => "lib-ebooks", "name" => "Ebooks", "mediaType" => "book", "folders" => [ { "fullPath" => "/ebooks" } ] }
        ] }.to_json
      )

      get admin_setup_wizard_url(step: "audiobookshelf")
      assert_select "details", count: 0
      assert_select "input[type=submit][value='Test and continue']", count: 1

      patch admin_setup_wizard_url(step: "audiobookshelf"), params: { wizard: { url: "http://audiobookshelf:13378", api_key: "abs-token" } }
      follow_redirect!

      assert_select "input[type=submit][value='Save and continue']", count: 1
      assert_select "details:not([open]) summary", "Change the Audiobookshelf connection"
      assert_select "select[name='wizard[audiobook_library_id]'] option[selected][value='lib-audio']"
      assert_select "select[name='wizard[ebook_library_id]'] option[selected][value='']"

      patch admin_setup_wizard_url(step: "audiobookshelf"), params: { wizard: { phase: "libraries", audiobook_library_id: "", ebook_library_id: "" } }
      get admin_setup_wizard_url(step: "audiobookshelf")

      assert_select "select[name='wizard[audiobook_library_id]'] option[selected][value='']"

      patch admin_setup_wizard_url(step: "audiobookshelf"), params: { wizard: { url: "http://audiobookshelf:13378", api_key: "" } }

      assert_redirected_to admin_setup_wizard_path(step: "audiobookshelf")
      assert_equal "abs-token", SettingsService.get(:audiobookshelf_api_key)
    end
  end

  test "a qbittorrent rerun keeps a saved api key when the username is filled in" do
    DownloadClient.create!(name: "qBittorrent", client_type: "qbittorrent", url: "http://qbittorrent:8080", username: "admin", api_key: QBITTORRENT_API_KEY, category: "", enabled: true)

    get admin_setup_wizard_url(step: "qbittorrent")
    assert_select "input[name='wizard[username]'][value='admin']"

    VCR.turned_off do
      stub_qbittorrent_connection("http://qbittorrent:8080")

      patch admin_setup_wizard_url(step: "qbittorrent"), params: {
        wizard: { url: "http://qbittorrent:8080", username: "admin", password: "", api_key: "", category: "" }
      }

      assert_redirected_to admin_setup_wizard_path(step: "folders")
      assert_not_requested :post, "http://qbittorrent:8080/api/v2/auth/login"
    end
    assert_equal QBITTORRENT_API_KEY, DownloadClient.qbittorrent.sole.api_key
  end

  test "saving audiobookshelf libraries syncs the library once and a blank choice does not" do
    SettingsService.set(:library_platform, "audiobookshelf")
    SettingsService.set(:audiobookshelf_url, "http://audiobookshelf:13378")
    SettingsService.set(:audiobookshelf_api_key, "abs-token")

    assert_enqueued_jobs 1, only: AudiobookshelfLibrarySyncJob do
      patch admin_setup_wizard_url(step: "audiobookshelf"), params: {
        wizard: { phase: "libraries", audiobook_library_id: "lib-audio", ebook_library_id: "" }
      }
    end

    assert_no_enqueued_jobs only: AudiobookshelfLibrarySyncJob do
      patch admin_setup_wizard_url(step: "audiobookshelf"), params: {
        wizard: { phase: "libraries", audiobook_library_id: "", ebook_library_id: "" }
      }
    end
  end

  private

  def reset_client_caches
    LibraryPlatformClient.reset_connections!
    IndexerClient.reset_all_connections!
    Thread.current[:qbittorrent_sessions] = {}
  end
end
