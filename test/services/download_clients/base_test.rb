# frozen_string_literal: true

require "test_helper"

class DownloadClients::BaseTest < ActiveSupport::TestCase
  setup do
    @client_record = DownloadClient.create!(
      name: "Test qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @client = @client_record.adapter
  end

  test "transient_http_status? recognizes client and gateway outages" do
    [ 408, 425, 429, 500, 502, 503, 504 ].each do |status|
      assert @client.send(:transient_http_status?, status), "expected #{status} to be transient"
    end

    [ 200, 202, 400, 401, 403, 404, 409 ].each do |status|
      assert_not @client.send(:transient_http_status?, status), "expected #{status} not to be transient"
    end
  end

  test "raise_for_http_status! raises ConnectionError only for transient statuses" do
    error = assert_raises(DownloadClients::Base::ConnectionError) do
      @client.send(:raise_for_http_status!, 503, "client unavailable")
    end
    assert_instance_of DownloadClients::Base::ConnectionError, error
    assert_equal "client unavailable", error.message

    error = assert_raises(DownloadClients::Base::Error) do
      @client.send(:raise_for_http_status!, 400, "bad request")
    end
    assert_instance_of DownloadClients::Base::Error, error
    assert_equal "bad request", error.message
  end

  test "resolve_guarded_torrent_source maps transient HTTP statuses to ConnectionError" do
    previous_resolver = OutboundUrlGuard.resolver
    OutboundUrlGuard.resolver = ->(_host) { [ "203.0.113.10" ] }

    VCR.turned_off do
      [ 408, 425, 429, 500, 503 ].each do |status|
        stub_request(:get, "https://files.test/book.torrent")
          .to_return(status: status, body: "unavailable")

        error = assert_raises(DownloadClients::Base::ConnectionError) do
          @client.send(:resolve_guarded_torrent_source, "https://files.test/book.torrent")
        end
        assert_instance_of DownloadClients::Base::ConnectionError, error
        assert_equal "Torrent source returned HTTP #{status}", error.message
      end
    end
  ensure
    OutboundUrlGuard.resolver = previous_resolver
  end

  test "resolve_guarded_torrent_source does not treat 400 or 404 as ConnectionError" do
    previous_resolver = OutboundUrlGuard.resolver
    OutboundUrlGuard.resolver = ->(_host) { [ "203.0.113.10" ] }

    VCR.turned_off do
      [ 400, 404 ].each do |status|
        stub_request(:get, "https://files.test/book.torrent")
          .to_return(status: status, body: "missing")

        source = @client.send(:resolve_guarded_torrent_source, "https://files.test/book.torrent")
        assert_equal "https://files.test/book.torrent", source[:url]
      end
    end
  ensure
    OutboundUrlGuard.resolver = previous_resolver
  end
end
