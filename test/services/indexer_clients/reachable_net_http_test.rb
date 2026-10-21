# frozen_string_literal: true

require "test_helper"

class IndexerClients::ReachableNetHttpTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key-12345")
    ProwlarrClient.reset_connection!
  end

  teardown do
    ProwlarrClient.reset_connection!
  end

  # A probe that finds nothing already used the open timeout. Falling through
  # to Net::HTTP spends that timeout again, and the idempotent retry doubles it.
  test "test_connection times out without a second connect when every address is unreachable" do
    clock = [ 0.0 ]
    lookups = 0
    connects = nil
    error = nil
    addresses = [ Addrinfo.tcp("192.0.2.1", 9696), Addrinfo.tcp("198.51.100.1", 9696) ]

    with_monotonic_clock(clock) do
      with_instant_select_timeout(clock) do
        Addrinfo.stub(:getaddrinfo, lambda { |*_args, **_kwargs|
          lookups += 1
          addresses
        }) do
          connects = count_tcp_connects do
            error = assert_raises(IndexerClients::Base::ConnectionError) do
              ProwlarrClient.test_connection
            end
          end
        end
      end
    end

    assert_equal "Connection timed out", error.message
    assert_equal 2, lookups
    assert_equal 0, connects
  end

  test "hostname resolution counts against the connect timeout" do
    open_timeout = 0.3
    resolved = false
    probes = 0
    original_probe = IndexerClients::ReachableNetHttp.method(:begin_address_probes)
    addresses = [ Addrinfo.tcp("192.0.2.1", 9), Addrinfo.tcp("198.51.100.1", 9) ]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    IndexerClients::ReachableNetHttp.stub(:begin_address_probes, lambda { |*args|
      probes += 1
      original_probe.call(*args)
    }) do
      Addrinfo.stub(:getaddrinfo, lambda { |*_args, **_kwargs|
        sleep(1.5)
        resolved = true
        addresses
      }) do
        raised = nil
        connects = count_tcp_connects do
          VCR.turned_off do
            connection = Faraday.new(url: "http://localhost:9696") do |builder|
              builder.options.open_timeout = open_timeout
              builder.options.timeout = 5
              IndexerClients::ReachableNetHttp.install(
                builder,
                "http://localhost:9696",
                open_timeout: open_timeout
              )
            end

            begin
              connection.get("/api/v1/indexer")
            rescue StandardError, WebMock::NetConnectNotAllowedError => error
              raised = error
            end
          end
        end

        assert_not resolved
        assert_equal 0, probes
        assert_equal 0, connects
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
        assert_instance_of Faraday::TimeoutError, raised
      end
    end
  end

  test "a later request reaches a new address when the previous one still answers" do
    first_socket = TCPServer.new("127.0.0.1", 0)
    port = first_socket.addr[1]
    servers = [
      StatusServer.new(first_socket, "500 Internal Server Error"),
      StatusServer.new(TCPServer.new("127.0.0.2", port), "200 OK")
    ]

    lookups = 0
    WebMock.allow_net_connect!
    with_env("http_proxy" => nil, "HTTP_PROXY" => nil, "https_proxy" => nil, "HTTPS_PROXY" => nil,
      "all_proxy" => nil, "ALL_PROXY" => nil, "no_proxy" => nil, "NO_PROXY" => nil) do
      VCR.turned_off do
        Addrinfo.stub(:getaddrinfo, lambda { |*_args, **_kwargs|
          lookups += 1
          target = lookups == 1 ? "127.0.0.1" : "127.0.0.2"
          [ Addrinfo.tcp("192.0.2.1", port), Addrinfo.tcp(target, port) ]
        }) do
          SettingsService.set(:prowlarr_url, "http://prowlarr.example:#{port}")
          ProwlarrClient.reset_connection!

          first = ProwlarrClient.send(:connection).get("api/v1/indexer")
          second = ProwlarrClient.send(:connection).get("api/v1/indexer")

          assert_equal 500, first.status
          assert_equal 200, second.status
        end
      end
    end
  ensure
    servers&.each(&:stop)
    WebMock.disable_net_connect!
    ProwlarrClient.reset_connection!
  end

  private

  def with_monotonic_clock(clock)
    Process.stub(:clock_gettime, ->(*) { clock[0] }) { yield }
  end

  def with_instant_select_timeout(clock)
    IO.stub(:select, lambda { |*args, **_kwargs|
      clock[0] += args[3].to_f
      nil
    }) { yield }
  end

  def count_tcp_connects
    connects = 0
    original = Net::HTTP.method(:new)
    Net::HTTP.stub(:new, lambda { |*args|
      http = original.call(*args)
      http.define_singleton_method(:connect) do
        connects += 1
        raise Errno::ETIMEDOUT
      end
      http
    }) { yield }

    connects
  end

  class StatusServer
    def initialize(tcp, status)
      @tcp = tcp
      @status = status
      @thread = Thread.new { serve }
    end

    def stop
      @tcp.close
      @thread.join(1)
    end

    private

    def serve
      loop do
        client = @tcp.accept
        respond(client)
      rescue IOError, Errno::EBADF
        break
      rescue StandardError
        client&.close
      end
    end

    def respond(client)
      head = +""
      while (line = client.gets)
        head << line
        break if line == "\r\n"
      end
      return if head.empty?

      body = "[]"
      client.write(
        "HTTP/1.1 #{@status}\r\nContent-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
      )
    ensure
      client&.close
    end
  end
end
