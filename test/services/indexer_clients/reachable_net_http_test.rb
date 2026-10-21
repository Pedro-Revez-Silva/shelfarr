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

  # A single result used to be discarded after the lookup, so Net::HTTP resolved
  # the name again with only the leftover open timeout.
  test "a single resolved address connects inside the remaining open timeout" do
    socket = TCPServer.new("127.0.0.1", 0)
    port = socket.addr[1]
    server = StatusServer.new(socket, "200 OK")
    host = "slow-prowlarr.example"
    pinned = Addrinfo.tcp("127.0.0.1", port)
    lookups = 0
    original_lookup = Addrinfo.method(:getaddrinfo)
    original_open = TCPSocket.method(:open)
    open_timeout = 0.3
    # Net::HTTP resolves through TCPSocket.open, which does not call
    # Addrinfo.getaddrinfo. Both have to be slow or the second lookup is free.
    slow_lookup = lambda { |name|
      next unless name == host

      lookups += 1
      sleep 0.2
      true
    }

    WebMock.allow_net_connect!
    with_env("http_proxy" => nil, "HTTP_PROXY" => nil, "https_proxy" => nil, "HTTPS_PROXY" => nil,
      "all_proxy" => nil, "ALL_PROXY" => nil, "no_proxy" => nil, "NO_PROXY" => nil) do
      VCR.turned_off do
        Addrinfo.stub(:getaddrinfo, lambda { |*args, **kwargs|
          if slow_lookup.call(args[0])
            [ pinned ]
          elsif kwargs.empty?
            original_lookup.call(*args)
          else
            original_lookup.call(*args, **kwargs)
          end
        }) do
          TCPSocket.stub(:open, lambda { |*args|
            if slow_lookup.call(args[0])
              original_open.call(pinned.ip_address, *args.drop(1))
            else
              original_open.call(*args)
            end
          }) do
            url = "http://#{host}:#{port}"
            plain = faraday_connection(url, open_timeout)
            patched = faraday_connection(url, open_timeout) do |builder|
              IndexerClients::ReachableNetHttp.install(builder, url, open_timeout: open_timeout)
            end

            assert_equal 200, plain.get("/").status
            before_patched = lookups
            assert_equal 200, patched.get("/").status
            assert_equal 1, lookups - before_patched
          end
        end
      end
    end
  ensure
    server&.stop
    WebMock.disable_net_connect!
  end

  # A failed lookup used to be ignored, so Net::HTTP resolved the name again
  # with the leftover budget and the idempotent retry reported a timeout.
  test "a failed lookup raises a resolve failure without a second lookup" do
    host = "missing-prowlarr.example"
    open_timeout = 0.3
    lookups = 0
    original_lookup = Addrinfo.method(:getaddrinfo)
    original_open = TCPSocket.method(:open)
    original_build = ProwlarrClient.method(:build_connection)
    # Net::HTTP resolves through TCPSocket.open, which does not call
    # Addrinfo.getaddrinfo. Both have to fail slowly or the second lookup is free.
    nxdomain = lambda { |name|
      next unless name == host

      lookups += 1
      sleep 0.2
      raise SocketError, "getaddrinfo: Name or service not known"
    }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = nil

    SettingsService.set(:prowlarr_url, "http://#{host}:9696")
    ProwlarrClient.reset_connection!
    WebMock.allow_net_connect!
    with_env("http_proxy" => nil, "HTTP_PROXY" => nil, "https_proxy" => nil, "HTTPS_PROXY" => nil,
      "all_proxy" => nil, "ALL_PROXY" => nil, "no_proxy" => nil, "NO_PROXY" => nil) do
      VCR.turned_off do
        ProwlarrClient.stub(:build_connection, lambda {
          connection = original_build.call
          connection.options.open_timeout = open_timeout
          connection
        }) do
          Addrinfo.stub(:getaddrinfo, lambda { |*args, **kwargs|
            nxdomain.call(args[0])
            kwargs.empty? ? original_lookup.call(*args) : original_lookup.call(*args, **kwargs)
          }) do
            TCPSocket.stub(:open, lambda { |*args|
              nxdomain.call(args[0])
              original_open.call(*args)
            }) do
              error = assert_raises(IndexerClients::Base::ConnectionError) do
                ProwlarrClient.test_connection
              end
            end
          end
        end
      end
    end

    assert_equal 2, lookups
    assert_equal "Could not resolve host", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.55
  ensure
    WebMock.disable_net_connect!
  end

  # Probes that all refuse used to return nothing, and Net::HTTP then opened
  # one more connection to the same dead addresses.
  test "refused addresses raise connection refused without another connect" do
    port = unused_port
    opens = 0
    original_open = TCPSocket.method(:open)
    addresses = [ Addrinfo.tcp("127.0.0.1", port), Addrinfo.tcp("127.0.0.2", port) ]
    url = "http://127.0.0.1:#{port}"
    error = nil

    WebMock.allow_net_connect!
    with_env("http_proxy" => nil, "HTTP_PROXY" => nil, "https_proxy" => nil, "HTTPS_PROXY" => nil,
      "all_proxy" => nil, "ALL_PROXY" => nil, "no_proxy" => nil, "NO_PROXY" => nil) do
      VCR.turned_off do
        Addrinfo.stub(:getaddrinfo, ->(*_args, **_kwargs) { addresses }) do
          TCPSocket.stub(:open, lambda { |*args|
            opens += 1
            original_open.call(*args)
          }) do
            connection = faraday_connection(url, 2) do |builder|
              IndexerClients::ReachableNetHttp.install(builder, url, open_timeout: 2)
            end

            error = assert_raises(Faraday::ConnectionFailed) { connection.get("/") }
          end
        end
      end
    end

    assert_equal 0, opens
    assert_instance_of Errno::ECONNREFUSED, error.wrapped_exception
  ensure
    WebMock.disable_net_connect!
  end

  # URI#host keeps the brackets, and getaddrinfo rejects "[::1]". The old
  # rescue swallowed that and let Net::HTTP resolve the literal itself.
  test "a bracketed IPv6 literal is pinned without a failed lookup" do
    socket = TCPServer.new("::1", 0)
    port = socket.addr[1]
    server = StatusServer.new(socket, "200 OK")
    url = "http://[::1]:#{port}"
    hosts = []
    original_lookup = Addrinfo.method(:getaddrinfo)

    WebMock.allow_net_connect!
    with_env("http_proxy" => nil, "HTTP_PROXY" => nil, "https_proxy" => nil, "HTTPS_PROXY" => nil,
      "all_proxy" => nil, "ALL_PROXY" => nil, "no_proxy" => nil, "NO_PROXY" => nil) do
      VCR.turned_off do
        Addrinfo.stub(:getaddrinfo, lambda { |*args, **kwargs|
          hosts << args[0]
          kwargs.empty? ? original_lookup.call(*args) : original_lookup.call(*args, **kwargs)
        }) do
          connection = faraday_connection(url, 2) do |builder|
            IndexerClients::ReachableNetHttp.install(builder, url, open_timeout: 2)
          end

          assert_equal 200, connection.get("/").status
        end
      end
    end

    assert_equal [ "::1" ], hosts
  ensure
    server&.stop
    WebMock.disable_net_connect!
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

  def unused_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def faraday_connection(url, open_timeout)
    Faraday.new(url: url) do |builder|
      builder.options.open_timeout = open_timeout
      builder.options.timeout = 2
      yield builder if block_given?
    end
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
