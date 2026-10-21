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
        ReachableAddress.assign_reachable_address(http, url, http.open_timeout || open_timeout)
      end
    end
  end
end
