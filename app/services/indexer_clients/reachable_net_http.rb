# frozen_string_literal: true

module IndexerClients
  # Net::HTTP uses one open timeout for every getaddrinfo result. A blackholed
  # first address — IPv6 localhost in Docker — expires before IPv4 is tried.
  module ReachableNetHttp
    module_function

    def install(connection, url, open_timeout:)
      ipaddr = pinned_ipaddr(connection, url, open_timeout)
      if ipaddr
        connection.adapter :net_http do |http|
          http.ipaddr = ipaddr
        end
      else
        connection.adapter Faraday.default_adapter
      end
    end

    def pinned_ipaddr(connection, url, open_timeout)
      return if connection.proxy

      ipaddr = reachable_ipaddr(url, open_timeout)
      ipaddr if ipaddr.is_a?(String)
    end

    def reachable_ipaddr(url, open_timeout)
      uri = URI(url.to_s)
      return if uri.host.blank?

      addresses = Addrinfo.getaddrinfo(uri.host, uri.port, nil, :STREAM)
      return if addresses.size < 2

      select_reachable_ipaddr(addresses, open_timeout)
    rescue SocketError, SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    def select_reachable_ipaddr(addresses, open_timeout)
      pending = begin_address_probes(addresses).grep(Array)
      return if pending.empty?

      winner = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + open_timeout
      begin
        until pending.empty? || winner
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          _readable, writable, erroneous = IO.select(nil, pending.map(&:first), pending.map(&:first), remaining)
          ready = Array(writable) | Array(erroneous)
          break if ready.empty?

          ready.each do |sock|
            candidate = take_connected_ipaddr(pending, sock)
            if candidate.is_a?(String)
              winner = candidate
              break
            elsif candidate
              pending.delete_if { |socket, _addr| socket == sock }
              close_probe_socket(sock)
            end
          end
        end
        winner
      ensure
        pending.each { |socket, _addr| close_probe_socket(socket) }
      end
    end

    def begin_address_probes(addresses)
      addresses.filter_map do |addr|
        socket = Socket.new(addr.afamily, Socket::SOCK_STREAM, 0)
        socket.connect_nonblock(addr, exception: false)
        [ socket, addr ]
      rescue SystemCallError => error
        close_probe_socket(socket)
        RemoteResult::Failed.new(error)
      end
    end

    def take_connected_ipaddr(pending, sock)
      pair = pending.find { |candidate, _addr| candidate == sock }
      return unless pair

      socket, addr = pair
      result = socket.connect_nonblock(addr, exception: false)
      error = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
      return addr.ip_address if result != :wait_writable && error.zero?

      return if result == :wait_writable && error.zero?

      close_probe_socket(socket)
      pending.delete(pair)
      nil
    rescue Errno::EISCONN
      addr.ip_address
    rescue IO::WaitWritable, Errno::EINPROGRESS, Errno::EALREADY => error
      RemoteResult::Failed.new(error)
    rescue SystemCallError => error
      close_probe_socket(socket)
      pending.delete(pair)
      RemoteResult::Failed.new(error)
    end

    def close_probe_socket(socket)
      socket&.close
    rescue IOError, SystemCallError => error
      RemoteResult::Failed.new(error)
    end
  end
end
