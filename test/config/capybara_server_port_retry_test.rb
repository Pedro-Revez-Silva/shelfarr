# frozen_string_literal: true

require "test_helper"
require "capybara"
require "rack/handler/puma"
require_relative "../support/capybara_server_port_retry"

class CapybaraServerPortRetryTest < ActiveSupport::TestCase
  test "a cached port collision boots Puma on a fresh port and updates its checker and cache" do
    with_owned_servers do |occupied, servers|
      app = ->(_env) { [ 200, { "content-type" => "text/plain" }, [ "ready" ] ] }
      Capybara::Server.ports[app.object_id] = occupied.addr[1]
      server = Capybara::Server.new(app)

      server.boot

      refute_equal occupied.addr[1], server.port
      assert server.responsive?
      assert_equal "ready", Net::HTTP.get(URI(server.base_url))
      assert_equal server.port, Capybara::Server.ports[app.object_id]
      assert_equal server.port, Capybara::Server.new(app).boot.port
      assert_equal 2, servers.length
    ensure
      Capybara::Server.ports.delete(app.object_id) if app
    end
  end

  test "automatic port retries are bounded" do
    with_owned_servers do |occupied, servers|
      app = ->(_env) { [ 200, {}, [ "ready" ] ] }
      Capybara::Server.ports[app.object_id] = occupied.addr[1]
      server = Capybara::Server.new(app)

      server.stub(:find_available_port, occupied.addr[1]) do
        assert_raises(Errno::EADDRINUSE) { server.boot }
      end

      assert_equal 4, servers.length
    ensure
      Capybara::Server.ports.delete(app.object_id) if app
    end
  end

  test "an explicitly configured port is not silently changed" do
    with_owned_servers do |occupied, servers|
      app = ->(_env) { [ 200, {}, [ "ready" ] ] }
      server = Capybara::Server.new(app, port: occupied.addr[1])

      assert_raises(Errno::EADDRINUSE) { server.boot }
      assert_equal 1, servers.length
    ensure
      Capybara::Server.ports.delete(app.object_id) if app
    end
  end

  private

  def with_owned_servers
    occupied = TCPServer.new("127.0.0.1", 0)
    listener = Thread.new do
      loop do
        socket = occupied.accept
        begin
          while (line = socket.gets)
            break if line == "\r\n"
          end
          socket.write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 8\r\n\r\noccupied")
        ensure
          socket.close
        end
      end
    end
    servers = []
    original = Puma::Server.method(:new)
    constructor = ->(*args, **options, &block) do
      original.call(*args, **options, &block).tap { |server| servers << server }
    end

    Puma::Server.stub(:new, constructor) do
      yield occupied, servers
    end
  ensure
    servers&.each { |server| server.stop(true) if server.running }
    listener&.kill&.join
    occupied&.close
  end
end
