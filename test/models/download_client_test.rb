# frozen_string_literal: true

require "test_helper"

class DownloadClientTest < ActiveSupport::TestCase
  test "validates presence of name" do
    client = DownloadClient.new(client_type: "qbittorrent", url: "http://localhost:8080")
    assert_not client.valid?
    assert_includes client.errors[:name], "can't be blank"
  end

  test "validates uniqueness of name" do
    DownloadClient.create!(name: "Test Client", client_type: "qbittorrent", url: "http://localhost:8080")
    client = DownloadClient.new(name: "Test Client", client_type: "qbittorrent", url: "http://localhost:9090")
    assert_not client.valid?
    assert_includes client.errors[:name], "has already been taken"
  end

  test "validates presence of url" do
    client = DownloadClient.new(name: "Test", client_type: "qbittorrent")
    assert_not client.valid?
    assert_includes client.errors[:url], "can't be blank"
  end

  test "validates presence of client_type" do
    client = DownloadClient.new(name: "Test", url: "http://localhost:8080")
    assert_not client.valid?
    assert_includes client.errors[:client_type], "can't be blank"
  end

  test "validates priority is non-negative integer" do
    client = DownloadClient.new(name: "Test", client_type: "qbittorrent", url: "http://localhost:8080", priority: -1)
    assert_not client.valid?
    assert_includes client.errors[:priority], "must be greater than or equal to 0"
  end

  test "creates qbittorrent adapter" do
    client = DownloadClient.create!(
      name: "qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password"
    )
    adapter = client.adapter
    assert_kind_of DownloadClients::Qbittorrent, adapter
    assert_equal client, adapter.config
  end

  test "creates deluge adapter" do
    client = DownloadClient.create!(
      name: "Deluge",
      client_type: "deluge",
      url: "http://localhost:8112",
      username: "admin",
      password: "password"
    )
    adapter = client.adapter
    assert_kind_of DownloadClients::Deluge, adapter
    assert_equal client, adapter.config
  end

  test "creates transmission adapter" do
    client = DownloadClient.create!(
      name: "Transmission",
      client_type: "transmission",
      url: "http://localhost:9091/transmission/rpc",
      username: "admin",
      password: "password"
    )
    adapter = client.adapter
    assert_kind_of DownloadClients::Transmission, adapter
    assert_equal client, adapter.config
  end

  test "creates sabnzbd adapter" do
    client = DownloadClient.create!(
      name: "SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "test-key"
    )
    adapter = client.adapter
    assert_kind_of DownloadClients::Sabnzbd, adapter
    assert_equal client, adapter.config
  end

  test "enabled scope returns only enabled clients" do
    enabled = DownloadClient.create!(name: "Enabled", client_type: "qbittorrent", url: "http://localhost:8080", enabled: true)
    disabled = DownloadClient.create!(name: "Disabled", client_type: "qbittorrent", url: "http://localhost:9090", enabled: false)

    assert_includes DownloadClient.enabled, enabled
    assert_not_includes DownloadClient.enabled, disabled
  end

  test "by_priority scope orders by priority ascending" do
    high = DownloadClient.create!(name: "High", client_type: "qbittorrent", url: "http://localhost:8080", priority: 0)
    low = DownloadClient.create!(name: "Low", client_type: "qbittorrent", url: "http://localhost:9090", priority: 10)
    mid = DownloadClient.create!(name: "Mid", client_type: "qbittorrent", url: "http://localhost:7070", priority: 5)

    clients = DownloadClient.by_priority.to_a
    assert_equal [high, mid, low], clients
  end

  test "torrent_clients scope returns torrent clients" do
    qb = DownloadClient.create!(name: "qBit", client_type: "qbittorrent", url: "http://localhost:8080")
    deluge = DownloadClient.create!(name: "Deluge", client_type: "deluge", url: "http://localhost:8112")
    transmission = DownloadClient.create!(name: "Transmission", client_type: "transmission", url: "http://localhost:9091/transmission/rpc")
    sab = DownloadClient.create!(name: "SAB", client_type: "sabnzbd", url: "http://localhost:9090", api_key: "key")

    assert_includes DownloadClient.torrent_clients, qb
    assert_includes DownloadClient.torrent_clients, deluge
    assert_includes DownloadClient.torrent_clients, transmission
    assert_not_includes DownloadClient.torrent_clients, sab
  end

  test "usenet_clients scope returns only sabnzbd" do
    qb = DownloadClient.create!(name: "qBit", client_type: "qbittorrent", url: "http://localhost:8080")
    sab = DownloadClient.create!(name: "SAB", client_type: "sabnzbd", url: "http://localhost:9090", api_key: "key")

    assert_includes DownloadClient.usenet_clients, sab
    assert_not_includes DownloadClient.usenet_clients, qb
  end

  test "encrypts password" do
    client = DownloadClient.create!(
      name: "Test",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      password: "secret123"
    )
    client.reload
    assert_equal "secret123", client.password
    # The raw value in the database should be encrypted
    assert_not_equal "secret123", client.password_before_type_cast
  end

  test "encrypts api_key" do
    client = DownloadClient.create!(
      name: "Test",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "secret-api-key"
    )
    client.reload
    assert_equal "secret-api-key", client.api_key
  end
end
