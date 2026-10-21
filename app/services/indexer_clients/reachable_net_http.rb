# frozen_string_literal: true

require "timeout"

module IndexerClients
  # Net::HTTP uses one open timeout for every getaddrinfo result. A blackholed
  # first address — IPv6 localhost in Docker — expires before IPv4 is tried.
  # Each connection probes again. Resolution and the probe share that timeout,
  # and a miss does not open another connection on a fresh budget.
  module ReachableNetHttp
    module_function

    def install(connection, url, open_timeout:)
      if connection.proxy
        connection.adapter Faraday.default_adapter
        return
      end

      connection.adapter :net_http do |http|
        assign_reachable_address(http, url, http.open_timeout || open_timeout)
      end
    end

    def assign_reachable_address(http, url, open_timeout)
      deadline = monotonic_deadline(open_timeout)
      ipaddr = reachable_ipaddr(url, deadline)
      raise Net::OpenTimeout, "execution expired" if ipaddr == :timeout

      http.ipaddr = ipaddr if ipaddr.is_a?(String)
      http.open_timeout = remaining_open_timeout(deadline)
    end

    def reachable_ipaddr(url, deadline)
      uri = URI(url.to_s)
      return if uri.host.blank?

      addresses = resolve_addresses(uri.host, uri.port, deadline)
      return :timeout if addresses == :timeout
      return if addresses.size < 2

      select_reachable_ipaddr(addresses, deadline)
    rescue SocketError, SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    def resolve_addresses(host, port, deadline)
      remaining = remaining_seconds(deadline)
      return :timeout unless remaining

      addresses = Timeout.timeout(remaining, Net::OpenTimeout) do
        Addrinfo.getaddrinfo(host, port, nil, :STREAM)
      end
      return :timeout unless remaining_seconds(deadline)

      addresses
    rescue Net::OpenTimeout
      :timeout
    end

    def select_reachable_ipaddr(addresses, deadline)
      pending = begin_address_probes(addresses).grep(Array)
      return if pending.empty?

      winner = nil
      timed_out = false
      begin
        until pending.empty? || winner
          remaining = remaining_seconds(deadline)
          if remaining.nil?
            timed_out = true
            break
          end

          _readable, writable, erroneous = IO.select(nil, pending.map(&:first), pending.map(&:first), remaining)
          ready = Array(writable) | Array(erroneous)
          if ready.empty?
            timed_out = true
            break
          end

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

        return :timeout if timed_out && winner.nil?

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

    def remaining_open_timeout(deadline)
      remaining = remaining_seconds(deadline)
      raise Net::OpenTimeout, "execution expired" unless remaining

      remaining
    end

    def remaining_seconds(deadline)
      remaining = deadline - monotonic_now
      remaining.positive? ? remaining : nil
    end

    def monotonic_deadline(open_timeout)
      monotonic_now + Float(open_timeout)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
