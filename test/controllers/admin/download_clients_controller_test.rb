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

  test "index renders ordered clients" do
    first = create_download_client(name: "First Client", url: "http://localhost:8081")
    second = create_download_client(name: "Second Client", url: "http://localhost:8082")
    second.update!(priority: first.priority + 1)

    get admin_download_clients_url

    assert_response :success
    assert_select "h1", "Download Clients"
    assert_select "td", "First Client"
    assert_select "td", "Second Client"
  end

  test "new renders form with default category" do
    get new_admin_download_client_url

    assert_response :success
    assert_select "form[action='#{admin_download_clients_path}']"
    assert_select "input[name='download_client[category]'][value='shelfarr']"
  end

  test "show displays client details without secrets" do
    client = create_download_client

    get admin_download_client_url(client)

    assert_response :success
    assert_select "h1", client.name
    assert_select "dd", client.client_type.titleize
    assert_select "dd", client.url
    assert_select "span", "Enabled"
    assert_select "dt", text: "Password", count: 0
    assert_select "dt", text: "API Key", count: 0
  end

  test "create renders errors for invalid client" do
    assert_no_difference -> { DownloadClient.count } do
      post admin_download_clients_url, params: {
        download_client: {
          name: "",
          client_type: "qbittorrent",
          url: "",
          torrent_verification_max_attempts: "0",
          torrent_verification_wait_time: "-1"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "form[action='#{admin_download_clients_path}']"
  end

  test "edit renders form" do
    client = create_download_client

    get edit_admin_download_client_url(client)

    assert_response :success
    assert_select "form[action='#{admin_download_client_path(client)}']"
  end

  test "update renders errors for invalid client" do
    client = create_download_client

    patch admin_download_client_url(client), params: {
      download_client: {
        name: "",
        url: ""
      }
    }

    assert_response :unprocessable_entity
    assert_select "form[action='#{admin_download_client_path(client)}']"
  end

  test "destroy removes client and clears monitor when none remain" do
    client = create_download_client

    assert_difference -> { DownloadClient.count }, -1 do
      delete admin_download_client_url(client)
    end

    assert_redirected_to admin_download_clients_path
    assert_equal "Download client was successfully deleted.", flash[:notice]
  end

  test "move actions swap priorities within same client type" do
    first = create_download_client(name: "Priority One", url: "http://localhost:8081")
    second = create_download_client(name: "Priority Two", url: "http://localhost:8082")
    first.update!(priority: 0)
    second.update!(priority: 1)

    post move_down_admin_download_client_url(first)

    assert_redirected_to admin_download_clients_path
    assert_equal 1, first.reload.priority
    assert_equal 0, second.reload.priority

    post move_up_admin_download_client_url(first)

    assert_redirected_to admin_download_clients_path
    assert_equal 0, first.reload.priority
    assert_equal 1, second.reload.priority
  end

  test "move actions ignore boundary clients" do
    client = create_download_client
    client.update!(priority: 0)

    post move_up_admin_download_client_url(client)

    assert_redirected_to admin_download_clients_path
    assert_equal 0, client.reload.priority
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

  def create_download_client(**attributes)
    DownloadClient.create!({
      name: "Test qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      torrent_verification_max_attempts: 10,
      torrent_verification_wait_time: 2,
      priority: 0,
      enabled: true
    }.merge(attributes))
  end
end
