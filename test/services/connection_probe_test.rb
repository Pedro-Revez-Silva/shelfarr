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

      assert_equal "Connection refused #{ConnectionErrorClassifier::LOCALHOST_HINT}", error.message
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
end
