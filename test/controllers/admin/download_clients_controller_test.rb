# frozen_string_literal: true

require "test_helper"

class Admin::DownloadClientsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
    Thread.current[:qbittorrent_sessions] = {}
  end

  test "test action updates system health to healthy when connection succeeds" do
    client = create_download_client

    VCR.turned_off do
      stub_qbittorrent_connection(client.url)

      post test_admin_download_client_url(client)

      assert_redirected_to admin_download_clients_path
      assert_match /successful/i, flash[:notice]

      health = SystemHealth.for_service("download_client")
      assert health.healthy?
      assert_includes health.message, "1 clients connected"
    end
  end

  test "test action updates system health to down when connection fails" do
    client = create_download_client

    VCR.turned_off do
      stub_request(:post, "#{client.url}/api/v2/auth/login")
        .to_return(status: 401, body: "Fails.")

      post test_admin_download_client_url(client)

      assert_redirected_to admin_download_clients_path
      assert_match /failed/i, flash[:alert]

      health = SystemHealth.for_service("download_client")
      assert health.down?
      assert_includes health.message, client.name
    end
  end

  test "create persists qBittorrent verification settings" do
    VCR.turned_off do
      stub_qbittorrent_connection("http://localhost:8081")

      assert_enqueued_with(job: DownloadMonitorJob) do
        post admin_download_clients_url, params: {
          download_client: {
            name: "Slow qBittorrent",
            client_type: "qbittorrent",
            url: "http://localhost:8081",
            username: "admin",
            password: "password",
            category: "shelfarr",
            enabled: "1",
            torrent_verification_max_attempts: "12",
            torrent_verification_wait_time: "3"
          }
        }
      end

      assert_redirected_to admin_download_clients_path

      client = DownloadClient.find_by!(name: "Slow qBittorrent")
      assert_equal 12, client.torrent_verification_max_attempts
      assert_equal 3, client.torrent_verification_wait_time
    end
  end

  test "update persists qBittorrent verification settings" do
    client = create_download_client

    VCR.turned_off do
      stub_qbittorrent_connection(client.url)

      assert_enqueued_with(job: DownloadMonitorJob) do
        patch admin_download_client_url(client), params: {
          download_client: {
            torrent_verification_max_attempts: "15",
            torrent_verification_wait_time: "4"
          }
        }
      end

      assert_redirected_to admin_download_clients_path
      assert_equal 15, client.reload.torrent_verification_max_attempts
      assert_equal 4, client.torrent_verification_wait_time
    end
  end

  test "update starts monitor when enabling a previously disabled client" do
    client = create_download_client
    client.update!(enabled: false)

    VCR.turned_off do
      stub_qbittorrent_connection(client.url)

      assert_enqueued_with(job: DownloadMonitorJob) do
        patch admin_download_client_url(client), params: {
          download_client: {
            enabled: "1"
          }
        }
      end

      assert client.reload.enabled?
    end
  end

  private

  def create_download_client
    DownloadClient.create!(
      name: "Test qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      torrent_verification_max_attempts: 10,
      torrent_verification_wait_time: 2,
      priority: 0,
      enabled: true
    )
  end
end
