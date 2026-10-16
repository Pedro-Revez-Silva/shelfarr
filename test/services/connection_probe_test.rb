# frozen_string_literal: true

require "test_helper"

class ConnectionProbeTest < ActiveSupport::TestCase
  setup do
    Thread.current[:qbittorrent_sessions] = {}
  end

  test "prowlarr probe adds the loopback hint and does not save settings" do
    SettingsService.set(:prowlarr_url, "")
    SettingsService.set(:prowlarr_api_key, "")

    VCR.turned_off do
      stub_request(:get, "http://127.0.0.1:9696/api/v1/indexer")
        .to_raise(Errno::ECONNREFUSED.new("Connection refused - connect(2)"))

      error = assert_raises(IndexerClients::Base::ConnectionError) do
        ConnectionProbe.indexer(provider: "prowlarr", url: "http://127.0.0.1:9696", api_key: "typed-key")
      end

      assert_equal "Connection refused. #{ConnectionErrorClassifier::LOCALHOST_HINT}", error.message
      assert_equal "", SettingsService.get(:prowlarr_url)
      assert_equal "", SettingsService.get(:prowlarr_api_key)
    end
  end

  test "qbittorrent probe uses an unsaved client and does not create a category" do
    VCR.turned_off do
      stub_request(:post, "http://qb.example:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=probe_session; path=/" },
          body: "Ok."
        )
      stub_request(:get, "http://qb.example:8080/api/v2/app/version")
        .to_return(status: 200, body: "v4.6.0")

      assert_no_difference "DownloadClient.count" do
        assert ConnectionProbe.qbittorrent(
          url: "http://qb.example:8080",
          username: "admin",
          password: "secret",
          category: "shelfarr"
        )
      end

      assert_not_requested :post, "http://qb.example:8080/api/v2/torrents/createCategory"
      assert_nil DownloadClient.find_by(url: "http://qb.example:8080")
    end
  end

  test "qbittorrent probes do not share a login between unsaved clients" do
    VCR.turned_off do
      stub_request(:post, "http://qb.example:8080/api/v2/auth/login")
        .with(body: hash_including("password" => "secret"))
        .to_return(status: 200, headers: { "Set-Cookie" => "SID=probe_session; path=/" }, body: "Ok.")
      stub_request(:post, "http://qb.example:8080/api/v2/auth/login")
        .with(body: hash_including("password" => "wrong"))
        .to_return(status: 200, body: "Fails.")
      stub_request(:get, "http://qb.example:8080/api/v2/app/version")
        .to_return(status: 200, body: "v4.6.0")

      assert ConnectionProbe.qbittorrent(url: "http://qb.example:8080", username: "admin", password: "secret")

      assert_raises(DownloadClients::Base::AuthenticationError) do
        ConnectionProbe.qbittorrent(url: "http://qb.example:8080", username: "admin", password: "wrong")
      end
      assert_empty Thread.current[:qbittorrent_sessions].to_h
    end
  end

  test "qbittorrent probe accepts a trailing slash without doubling the login path" do
    VCR.turned_off do
      stub_request(:post, "http://qb.example:8080/api/v2/auth/login")
        .to_return(status: 200, headers: { "Set-Cookie" => "SID=probe_session; path=/" }, body: "Ok.")
      stub_request(:get, "http://qb.example:8080/api/v2/app/version")
        .to_return(status: 200, body: "v4.6.0")

      assert ConnectionProbe.qbittorrent(url: "http://qb.example:8080/", username: "admin", password: "secret")
    end
  end

  test "qbittorrent probe names an invalid URL before connecting" do
    error = assert_raises(DownloadClients::Base::ConnectionError) do
      ConnectionProbe.qbittorrent(url: "qbittorrent:8080", username: "admin", password: "secret")
    end

    assert_equal "qBittorrent URL must be a valid HTTP or HTTPS URL", error.message
  end
end
