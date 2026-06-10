# frozen_string_literal: true

require "test_helper"
require "base64"
require "bencode"

class DownloadClients::TransmissionTest < ActiveSupport::TestCase
  JSONRPC_TORRENT_FIELDS = %w[
    id
    name
    hash_string
    percent_done
    status
    total_size
    download_dir
    error
    error_string
  ].freeze

  LEGACY_TORRENT_FIELDS = %w[
    id
    name
    hashString
    percentDone
    status
    totalSize
    downloadDir
    error
    errorString
  ].freeze

  setup do
    DownloadClient.destroy_all
    @client_record = DownloadClient.create!(
      name: "Test Transmission",
      client_type: "transmission",
      url: "http://localhost:9091/transmission/rpc",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
    @client = @client_record.adapter

    Thread.current[:transmission_sessions] = {}
    Thread.current[:transmission_protocols] = {}
  end

  test "add_torrent adds torrent and returns hash" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => "all", "fields" => [ "hash_string" ] }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrents" => [ { "hash_string" => "existing" } ] }, "id" => 1 }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with do |request|
          jsonrpc_request?(request, method: "torrent_add", params: { "filename" => "magnet:?xt=urn:btih:abcdef" })
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrent_added" => { "hash_string" => "new-torrent-id" } }, "id" => 1 }.to_json
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:abcdef")
      assert_equal "new-torrent-id", result
    end
  end

  test "add_torrent uploads fetched torrent payload via metainfo" do
    VCR.turned_off do
      torrent_data = {
        "info" => {
          "name" => "Transmission Book.epub",
          "piece length" => 16384,
          "pieces" => "s" * 20,
          "length" => 512
        }
      }.bencode

      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:get, "http://prowlarr:9696/api/v1/indexer/download/123")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/x-bittorrent" },
          body: torrent_data
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => "all", "fields" => [ "hash_string" ] }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrents" => [] }, "id" => 1 }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with do |request|
          jsonrpc_request?(request, method: "torrent_add", params: {
            "metainfo" => Base64.strict_encode64(torrent_data),
            "paused" => true,
            "download_dir" => "/downloads/books"
          })
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "result" => {
              "torrent_added" => { "hash_string" => "new-torrent-id" }
            },
            "id" => 1
          }.to_json
        )

      result = @client.add_torrent("http://prowlarr:9696/api/v1/indexer/download/123", paused: true, save_path: "/downloads/books")
      assert_equal "new-torrent-id", result
    end
  end

  test "add_torrent returns existing torrent id when duplicate" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => "all", "fields" => [ "hash_string" ] }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrents" => [ { "hash_string" => "existing" } ] }, "id" => 1 }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_add", params: { "filename" => "magnet:?xt=urn:btih:existing" }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrent_duplicate" => { "hash_string" => "existing" } }, "id" => 1 }.to_json
        )

      result = @client.add_torrent("magnet:?xt=urn:btih:existing")
      assert_equal "existing", result
    end
  end

  test "add_torrent falls back to new torrent ids when response has no hash" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => "all", "fields" => [ "hash_string" ] }) }
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "jsonrpc" => "2.0", "result" => { "torrents" => [ { "hash_string" => "existing" } ] }, "id" => 1 }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "jsonrpc" => "2.0", "result" => { "torrents" => [ { "hash_string" => "existing" }, { "hash_string" => "new-from-list" } ] }, "id" => 1 }.to_json
          }
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_add", params: { "filename" => "magnet:?xt=urn:btih:new" }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => {}, "id" => 1 }.to_json
        )

      assert_equal "new-from-list", @client.add_torrent("magnet:?xt=urn:btih:new")
    end
  end

  test "list_torrents returns array of TorrentInfo" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => "all", "fields" => JSONRPC_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "result" => {
              "torrents" => [
                {
                  "hash_string" => "abc123",
                  "name" => "Transmission Book",
                  "percent_done" => 0.5,
                  "status" => 4,
                  "total_size" => 1073741824,
                  "download_dir" => "/downloads/Transmission Book"
                }
              ]
            },
            "id" => 1
          }.to_json
        )

      torrents = @client.list_torrents

      assert_kind_of Array, torrents
      assert_equal 1, torrents.size

      torrent = torrents.first
      assert_kind_of DownloadClients::Base::TorrentInfo, torrent
      assert_equal "abc123", torrent.hash
      assert_equal "Transmission Book", torrent.name
      assert_equal 50, torrent.progress
      assert_equal :downloading, torrent.state
    end
  end

  test "reuses negotiated json-rpc protocol without re-authenticating" do
    VCR.turned_off do
      session_stub = stub_session_handshake("http://localhost:9091/transmission/rpc")
      list_stub = stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => "all", "fields" => JSONRPC_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrents" => [] }, "id" => 1 }.to_json
        )

      assert @client.test_connection
      assert_equal [], @client.list_torrents

      assert_requested(session_stub, times: 3)
      assert_requested(list_stub, times: 1)
    end
  end

  test "torrent_info returns nil when missing" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => [ "missing" ], "fields" => JSONRPC_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "result" => { "torrents" => [] },
            "id" => 1
          }.to_json
        )

      info = @client.torrent_info("missing")
      assert_nil info
    end
  end

  test "torrent_info maps local errors to failed state" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => [ "abc123" ], "fields" => JSONRPC_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "result" => {
              "torrents" => [
                {
                  "hash_string" => "abc123",
                  "name" => "Broken Transmission Book",
                  "percent_done" => 0.2,
                  "status" => 4,
                  "error" => 3,
                  "error_string" => "Permission denied",
                  "total_size" => 1073741824,
                  "download_dir" => "/downloads/Broken Transmission Book"
                }
              ]
            },
            "id" => 1
          }.to_json
        )

      info = @client.torrent_info("abc123")

      assert_equal :failed, info.state
      assert info.failed?
    end
  end

  test "torrent_info requests Transmission JSON-RPC snake_case field names" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => [ "abc123" ], "fields" => JSONRPC_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "result" => {
              "torrents" => [
                {
                  "id" => 7,
                  "name" => "Transmission Book",
                  "hash_string" => "abc123",
                  "percent_done" => 0.5,
                  "status" => 4,
                  "total_size" => 1073741824,
                  # Transmission reports the PARENT download dir here, not the
                  # per-torrent path; the content lives at download_dir/name.
                  "download_dir" => "/downloads",
                  "error" => 0,
                  "error_string" => ""
                }
              ]
            },
            "id" => 1
          }.to_json
        )

      info = @client.torrent_info("abc123")

      assert_equal "abc123", info.hash
      assert_equal 50, info.progress
      assert_equal "/downloads/Transmission Book", info.download_path
    end
  end

  test "torrent_info reports the per-torrent content path (download_dir + name)" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => [ "abc123" ], "fields" => JSONRPC_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "result" => {
              "torrents" => [
                {
                  "hash_string" => "abc123",
                  "name" => "Some Author - Some Book",
                  "percent_done" => 1.0,
                  "status" => 6,
                  "total_size" => 1073741824,
                  "download_dir" => "/mnt/media/transmission",
                  "error" => 0
                }
              ]
            },
            "id" => 1
          }.to_json
        )

      info = @client.torrent_info("abc123")

      # download_dir is the parent; the importable path is download_dir/name,
      # mirroring qBittorrent's content_path. Reporting the bare parent here
      # makes PostProcessingJob import the whole download root.
      assert_equal "/mnt/media/transmission/Some Author - Some Book", info.download_path
    end
  end

  test "torrent_info falls back to download_dir when name is blank" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => [ "abc123" ], "fields" => JSONRPC_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "result" => {
              "torrents" => [
                {
                  "hash_string" => "abc123",
                  "name" => "",
                  "percent_done" => 1.0,
                  "status" => 6,
                  "total_size" => 1073741824,
                  "download_dir" => "/downloads",
                  "error" => 0
                }
              ]
            },
            "id" => 1
          }.to_json
        )

      info = @client.torrent_info("abc123")

      assert_equal "/downloads", info.download_path
    end
  end

  test "list_torrents still parses legacy field names after legacy fallback" do
    VCR.turned_off do
      Thread.current[:transmission_sessions][@client_record.id] = "session-id"
      Thread.current[:transmission_protocols][@client_record.id] = :legacy

      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| legacy_request?(request, method: "torrent-get", arguments: { "ids" => "all", "fields" => LEGACY_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => "success",
            "arguments" => {
              "torrents" => [
                {
                  "hashString" => "legacy123",
                  "name" => "Legacy Transmission Book",
                  "percentDone" => 0.75,
                  "status" => 4,
                  "totalSize" => 2048,
                  "downloadDir" => "/downloads/legacy"
                }
              ]
            }
          }.to_json
        )

      torrent = @client.list_torrents.first

      assert_equal "legacy123", torrent.hash
      assert_equal "Legacy Transmission Book", torrent.name
      assert_equal 75, torrent.progress
      assert_equal :downloading, torrent.state
      assert_equal 2048, torrent.size_bytes
      # downloadDir is the parent; download_path is the per-torrent content path
      # (downloadDir/name), same as the JSON-RPC path.
      assert_equal "/downloads/legacy/Legacy Transmission Book", torrent.download_path
    end
  end

  test "json-rpc errors include error_string details" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_get", params: { "ids" => "all", "fields" => [ "hash_string" ] }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "torrents" => [] }, "id" => 1 }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_add", params: { "filename" => "magnet:?xt=urn:btih:error" }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "jsonrpc" => "2.0",
            "error" => {
              "code" => 7,
              "message" => "HTTP error from backend service",
              "data" => { "error_string" => "Couldn't fetch torrent: No Response (0)" }
            },
            "id" => 1
          }.to_json
        )

      error = assert_raises(DownloadClients::Base::Error) do
        @client.add_torrent("magnet:?xt=urn:btih:error")
      end

      assert_equal "Transmission API error for torrent_add: HTTP error from backend service: Couldn't fetch torrent: No Response (0)", error.message
    end
  end

  test "parse_response handles http legacy and json-rpc error branches" do
    unauthorized = transmission_response(status: 401, body: {})
    assert_raises(DownloadClients::Base::AuthenticationError) do
      @client.send(:parse_response, unauthorized, "session-get", :jsonrpc)
    end

    server_error = transmission_response(status: 500, body: {})
    assert_raises(DownloadClients::Base::Error) do
      @client.send(:parse_response, server_error, "session-get", :jsonrpc)
    end

    unexpected_body = transmission_response(status: 200, body: "not a hash")
    assert_raises(DownloadClients::Base::Error) do
      @client.send(:parse_response, unexpected_body, "session-get", :jsonrpc)
    end

    assert_raises(DownloadClients::Transmission::LegacyProtocolRequired) do
      @client.send(:parse_response, transmission_response(status: 200, body: { "result" => "success" }), "session-get", :jsonrpc)
    end

    assert_raises(DownloadClients::Base::AuthenticationError) do
      @client.send(:parse_response, transmission_response(status: 200, body: { "result" => "session" }), "session-get", :legacy)
    end

    assert_raises(DownloadClients::Base::Error) do
      @client.send(:parse_response, transmission_response(status: 200, body: { "result" => "failure" }), "torrent-add", :legacy)
    end

    assert_equal({}, @client.send(:parse_response, transmission_response(status: 200, body: { "result" => "success" }), "session-get", :legacy))
  end

  test "parse_jsonrpc_response rejects missing result hash" do
    assert_raises(DownloadClients::Base::Error) do
      @client.send(:parse_jsonrpc_response, { "jsonrpc" => "2.0", "result" => "ok" }, "session-get")
    end
  end

  test "remove_torrent returns true on success" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "torrent_remove", params: { "ids" => [ "abc123" ], "delete_local_data" => true }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => {}, "id" => 1 }.to_json
        )

      assert @client.remove_torrent("abc123", delete_files: true)
    end
  end

  test "test_connection returns false on authentication failure" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "session_get", params: {}) }
        .to_return(
          status: 401,
          headers: { "Content-Type" => "application/json" },
          body: ""
        )

      assert_not @client.test_connection
    end
  end

  test "test_connection returns true on success" do
    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")

      assert @client.test_connection
    end
  end

  test "test_connection accepts json-rpc response format" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "session_get", params: {}) }
        .to_return(
          {
            status: 409,
            headers: { "x-transmission-session-id" => "session-id" },
            body: { "result" => "session", "arguments" => {} }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "jsonrpc" => "2.0", "result" => { "version" => "4.1.1" }, "id" => 1 }.to_json
          }
        )

      assert @client.test_connection
    end
  end

  test "falls back to legacy protocol when json-rpc is unsupported" do
    VCR.turned_off do
      modern_probe = stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| jsonrpc_request?(request, method: "session_get", params: {}) }
        .to_return(
          {
            status: 409,
            headers: { "x-transmission-session-id" => "session-id" },
            body: { "result" => "session", "arguments" => {} }.to_json
          },
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => "success", "arguments" => {} }.to_json
          }
        )
      legacy_probe = stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| legacy_request?(request, method: "session-get", arguments: {}) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => {} }.to_json
        )
      legacy_list = stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with { |request| legacy_request?(request, method: "torrent-get", arguments: { "ids" => "all", "fields" => LEGACY_TORRENT_FIELDS }) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => "success", "arguments" => { "torrents" => [] } }.to_json
        )

      assert @client.test_connection
      assert_equal [], @client.list_torrents
      assert_requested(modern_probe, times: 2)
      assert_requested(legacy_probe, times: 2)
      assert_requested(legacy_list)
    end
  end

  test "test_connection uses rpc path when configured url is host root" do
    @client_record.update!(url: "http://localhost:9091")
    @client = @client_record.adapter

    VCR.turned_off do
      stub_session_handshake("http://localhost:9091/transmission/rpc")

      assert @client.test_connection
    end
  end

  test "resolve_torrent_source follows redirects and extracts magnets" do
    VCR.turned_off do
      stub_request(:get, "http://example.com/start")
        .to_return(status: 302, headers: { "Location" => "/landing" }, body: "")
      stub_request(:get, "http://example.com/landing")
        .to_return(status: 200, body: "<a href=\"magnet:?xt=urn:btih:abc\">torrent</a>")

      source = @client.send(:resolve_torrent_source, "http://example.com/start")

      assert_equal "magnet:?xt=urn:btih:abc", source[:url]
    end
  end

  test "resolve_torrent_source handles invalid urls failed requests and too many redirects" do
    assert_nil @client.send(:resolve_torrent_source, "http://[bad")

    VCR.turned_off do
      stub_request(:get, "http://example.com/fail").to_timeout
      assert_nil @client.send(:resolve_torrent_source, "http://example.com/fail")

      stub_request(:get, %r{http://example.com/loop})
        .to_return(status: 302, headers: { "Location" => "http://example.com/loop" }, body: "")
      source = @client.send(:resolve_torrent_source, "http://example.com/loop")
      assert_equal "http://example.com/loop", source[:url]
    end
  end

  test "normalizes torrent data urls states and rpc urls" do
    valid_torrent = { "info" => { "name" => "Book", "piece length" => 16_384, "pieces" => "x" * 20, "length" => 1 } }.bencode

    assert @client.send(:valid_torrent_data?, valid_torrent)
    assert_not @client.send(:valid_torrent_data?, "not-bencode")
    assert_nil @client.send(:normalized_torrent_url, "ftp://example.com/file.torrent")
    assert_equal "magnet:?xt=urn:btih:abc", @client.send(:absolutize_redirect_url, "http://example.com/base", "magnet:?xt=urn:btih:abc")
    assert_nil @client.send(:absolutize_redirect_url, "http://example.com/base", "ftp://example.com/file")
    assert_nil @client.send(:absolutize_redirect_url, "http://example.com/base", "http://[bad")

    assert_equal :paused, @client.send(:normalize_state, 0)
    assert_equal :queued, @client.send(:normalize_state, 1)
    assert_equal :queued, @client.send(:normalize_state, 3)
    assert_equal :queued, @client.send(:normalize_state, 5)
    assert_equal :completed, @client.send(:normalize_state, 6)
    assert_equal :downloading, @client.send(:normalize_state, 99)
    assert_equal :failed, @client.send(:normalize_state, 4, error: 3)

    @client_record.update!(url: "http://localhost:9091/transmission/rpc/")
    assert_equal "http://localhost:9091/transmission/rpc", @client_record.adapter.send(:rpc_url)
    @client_record.url = "http://[bad"
    assert_equal "http://[bad", @client_record.adapter.send(:rpc_url)
  end

  test "uses basic authentication header when username and password are set" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(
          body: lambda { |body|
            parsed = JSON.parse(body)
            parsed["jsonrpc"] == "2.0" &&
              parsed["method"] == "session_get" &&
              parsed["params"] == {} &&
              parsed["id"] == 1
          },
          basic_auth: [ "admin", "adminadmin" ]
        )
        .to_return(
          status: 409,
          headers: { "x-transmission-session-id" => "session-id" },
          body: { "result" => "session", "arguments" => {} }.to_json
        )
      stub_request(:post, "http://localhost:9091/transmission/rpc")
        .with(
          body: lambda { |body|
            parsed = JSON.parse(body)
            parsed["jsonrpc"] == "2.0" &&
              parsed["method"] == "session_get" &&
              parsed["params"] == {} &&
              parsed["id"] == 1
          },
          basic_auth: [ "admin", "adminadmin" ]
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "version" => "4.1.1" }, "id" => 1 }.to_json
        )

      assert @client.test_connection
    end
  end

  private

  def stub_session_handshake(url)
    stub_request(:post, url)
      .with { |request| jsonrpc_request?(request, method: "session_get", params: {}) }
      .to_return(
        {
          status: 409,
          headers: { "x-transmission-session-id" => "session-id" },
          body: { "result" => "session", "arguments" => {} }.to_json
        },
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "jsonrpc" => "2.0", "result" => { "version" => "4.1.1" }, "id" => 1 }.to_json
        }
      )
  end

  def jsonrpc_request?(request, method:, params:)
    body = JSON.parse(request.body)
    body["jsonrpc"] == "2.0" &&
      body["method"] == method &&
      body["params"] == params &&
      body["id"] == 1
  end

  def legacy_request?(request, method:, arguments:)
    body = JSON.parse(request.body)
    body["method"] == method &&
      body["arguments"] == arguments &&
      body["tag"] == 1
  end

  def transmission_response(status:, body:, headers: {})
    Struct.new(:status, :body, :headers).new(status, body, headers)
  end
end
