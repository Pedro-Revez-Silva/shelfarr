# frozen_string_literal: true

require "net/http"
require "socket"
require "timeout"

module ReachableAddress
  module_function

  def reachable_ipaddr(url, deadline)
    uri = URI(url.to_s)
    # URI#host keeps the brackets on an IPv6 literal, which getaddrinfo rejects.
    host = uri.hostname
    return if host.blank?

    addresses = resolve_addresses(host, uri.port, deadline)
    return :timeout if addresses == :timeout
    return if addresses.empty?
    # Net::HTTP resolves the hostname again. A single result has to be kept,
    # or that second lookup spends the time left after this one.
    return addresses.first.ip_address if addresses.one?

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
    probes = begin_address_probes(addresses)
    pending = probes.grep(Array)
    failure = probes.reverse_each.find { |probe| probe.is_a?(RemoteResult::Failed) }
    return failure if pending.empty?

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
          elsif candidate.is_a?(RemoteResult::Failed)
            failure = candidate
            pending.delete_if { |socket, _addr| socket == sock }
            close_probe_socket(sock)
          end
        end
      end

      return :timeout if timed_out && winner.nil?
      # Every address failed before the deadline. Returning nothing would
      # let Net::HTTP open another connection.
      return failure if winner.nil?

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
    return if error.zero?

    RemoteResult::Failed.new(SystemCallError.new("connect(2)", error))
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
