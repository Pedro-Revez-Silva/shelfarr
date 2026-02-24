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

  private

  def create_download_client
    DownloadClient.create!(
      name: "Test qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password",
      priority: 0,
      enabled: true
    )
  end
end
