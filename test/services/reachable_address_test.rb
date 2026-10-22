# frozen_string_literal: true

require "test_helper"

class ReachableAddressTest < ActiveSupport::TestCase
  test "a single resolved address is returned without opening a probe" do
    probes = 0
    address = Addrinfo.tcp("127.0.0.1", 9)

    assert_sockets_unchanged do
      Addrinfo.stub(:getaddrinfo, ->(*) { [ address ] }) do
        ReachableAddress.stub(:begin_address_probes, lambda { |*|
          probes += 1
          flunk "a single address must not be probed"
        }) do
          assert_equal "127.0.0.1", ReachableAddress.reachable_ipaddr("http://single.example:9", deadline(1))
        end
      end
    end

    assert_equal 0, probes
  end

  test "an IPv4 listener wins when IPv6 is refused" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    addresses = [ Addrinfo.tcp("::1", port), Addrinfo.tcp("127.0.0.1", port) ]
    result = nil

    assert_sockets_unchanged do
      Addrinfo.stub(:getaddrinfo, ->(*) { addresses }) do
        result = ReachableAddress.reachable_ipaddr("http://mixed.example:#{port}", deadline(2))
      end
    end

    assert_equal "127.0.0.1", result
  ensure
    server&.close
  end

  test "an IPv4 listener wins when IPv6 localhost is blackholed" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    addresses = [ Addrinfo.tcp("::1", port), Addrinfo.tcp("127.0.0.1", port) ]
    result = nil
    started = monotonic_now

    assert_sockets_unchanged do
      with_blackholed_ipv6(port) do
        Addrinfo.stub(:getaddrinfo, ->(*) { addresses }) do
          result = ReachableAddress.reachable_ipaddr("http://localhost:#{port}", deadline(2))
        end
      end
    end

    assert_equal "127.0.0.1", result
    assert_operator monotonic_now - started, :<, 1.0
  ensure
    server&.close
  end

  test "every refused address returns that failure and closes its socket" do
    port = unused_port
    addresses = [ Addrinfo.tcp("127.0.0.1", port), Addrinfo.tcp("127.0.0.2", port) ]
    result = nil

    assert_sockets_unchanged do
      Addrinfo.stub(:getaddrinfo, ->(*) { addresses }) do
        result = ReachableAddress.reachable_ipaddr("http://127.0.0.1:#{port}", deadline(2))
      end
    end

    assert_instance_of RemoteResult::Failed, result
    assert_instance_of Errno::ECONNREFUSED, result.error
  end

  test "a failed lookup returns the resolve error without opening a socket" do
    lookups = 0
    result = nil

    assert_sockets_unchanged do
      Addrinfo.stub(:getaddrinfo, lambda { |*|
        lookups += 1
        raise SocketError, "getaddrinfo: Name or service not known"
      }) do
        result = ReachableAddress.reachable_ipaddr("http://missing.example:9", deadline(1))
      end
    end

    assert_equal 1, lookups
    assert_instance_of RemoteResult::Failed, result
    assert_instance_of SocketError, result.error
  end

  test "hostname resolution counts against the address deadline" do
    probes = 0
    result = nil
    started = monotonic_now

    ReachableAddress.stub(:begin_address_probes, lambda { |*|
      probes += 1
      []
    }) do
      Addrinfo.stub(:getaddrinfo, lambda { |*|
        sleep 0.7
        [ Addrinfo.tcp("127.0.0.1", 9), Addrinfo.tcp("127.0.0.2", 9) ]
      }) do
        result = ReachableAddress.reachable_ipaddr("http://slow.example:9", deadline(0.25))
      end
    end

    assert_equal :timeout, result
    assert_equal 0, probes
    assert_operator monotonic_now - started, :<, 0.55
  end

  test "one address that cannot open a socket does not hide a reachable one" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    addresses = [ Addrinfo.tcp("2001:db8::1", port), Addrinfo.tcp("127.0.0.1", port) ]
    real_new = Socket.method(:new)
    result = nil

    assert_sockets_unchanged do
      Addrinfo.stub(:getaddrinfo, ->(*) { addresses }) do
        Socket.stub(:new, lambda { |family, *args|
          raise Errno::EAFNOSUPPORT, "Address family not supported by protocol" if family == Socket::AF_INET6

          real_new.call(family, *args)
        }) do
          result = ReachableAddress.reachable_ipaddr("http://mixed.example:#{port}", deadline(2))
        end
      end
    end

    assert_equal "127.0.0.1", result
  ensure
    server&.close
  end

  test "the open timeout covers resolution and probing without another connect" do
    opens = 0
    original_open = TCPSocket.method(:open)
    started = monotonic_now

    TCPSocket.stub(:open, lambda { |*args, **kwargs|
      opens += 1
      kwargs.empty? ? original_open.call(*args) : original_open.call(*args, **kwargs)
    }) do
      IO.stub(:select, lambda { |*args, **_kwargs|
        sleep args[3].to_f
        nil
      }) do
        Addrinfo.stub(:getaddrinfo, lambda { |*|
          sleep 0.2
          [ Addrinfo.tcp("127.0.0.1", 9), Addrinfo.tcp("127.0.0.2", 9) ]
        }) do
          http = Net::HTTP.new("budget.example", 9)
          http.open_timeout = 0.5
          assert_sockets_unchanged do
            assert_raises(Net::OpenTimeout) do
              ReachableAddress.assign_reachable_address(http, "http://budget.example:9", http.open_timeout)
            end
          end
        end
      end
    end

    assert_equal 0, opens
    assert_operator monotonic_now - started, :<, 0.65
  end

  private

  def deadline(seconds)
    monotonic_now + seconds
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def unused_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def with_blackholed_ipv6(port)
    rule = [ "-p", "tcp", "-d", "::1", "--dport", port.to_s, "-j", "DROP" ]
    installed = system("sudo", "-n", "ip6tables", "-I", "INPUT", *rule, out: File::NULL, err: File::NULL)
    raise "ip6tables could not blackhole ::1:#{port}" unless installed

    yield
  ensure
    system("sudo", "-n", "ip6tables", "-D", "INPUT", *rule, out: File::NULL, err: File::NULL) if installed
  end

  def assert_sockets_unchanged
    before = socket_count
    yield
  ensure
    assert_equal before, socket_count unless before.nil?
  end

  def socket_count
    Dir.each_child("/proc/self/fd").count do |entry|
      File.readlink("/proc/self/fd/#{entry}").start_with?("socket:")
    rescue Errno::ENOENT
      false
    end
  end
end
