# frozen_string_literal: true

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
      deadline = ReachableAddress.monotonic_deadline(open_timeout)
      ipaddr = reachable_ipaddr(url, deadline)
      raise Net::OpenTimeout, "execution expired" if ipaddr == :timeout
      if ipaddr.is_a?(RemoteResult::Failed)
        # Raise from connect. A stubbed Net::HTTP never reaches it, and a real
        # one must not spend the leftover budget on another lookup or socket.
        fail_connection(http, ipaddr.error)
        return
      end

      http.ipaddr = ipaddr if ipaddr.is_a?(String)
      http.open_timeout = ReachableAddress.remaining_open_timeout(deadline)
    end

    def fail_connection(http, error)
      http.define_singleton_method(:connect) { raise error }
    end

    def reachable_ipaddr(url, deadline)
      ReachableAddress.reachable_ipaddr(url, deadline)
    end
  end
end
