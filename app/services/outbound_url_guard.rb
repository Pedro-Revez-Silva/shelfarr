# frozen_string_literal: true

require "ipaddr"
require "resolv"
require "uri"

# Validates URLs before Shelfarr makes server-side HTTP requests to them,
# blocking requests to link-local/metadata addresses always and to private
# networks unless the caller explicitly allows them (admin-configured
# providers on a home-lab LAN).
class OutboundUrlGuard
  class BlockedUrlError < StandardError; end
  ValidatedUrl = Data.define(:uri, :ipaddr) do
    delegate :host, :port, :request_uri, :scheme, :to_s, to: :uri

    def use_ssl?
      scheme == "https"
    end
  end

  # Never reachable, regardless of configuration: unspecified, link-local
  # (incl. cloud metadata at 169.254.169.254), multicast, and reserved space.
  ALWAYS_BLOCKED_RANGES = %w[
    0.0.0.0/8
    100.100.100.200/32
    169.254.0.0/16
    224.0.0.0/4
    240.0.0.0/4
    ::/128
    64:ff9b::/96
    fd00:a9fe:a9fe::1/128
    fd00:ec2::254/128
    fd20:ce::254/128
    fe80::/10
    ff00::/8
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  # Reachable only when the caller opts in via allow_private.
  PRIVATE_RANGES = %w[
    10.0.0.0/8
    100.64.0.0/10
    127.0.0.0/8
    172.16.0.0/12
    192.168.0.0/16
    ::1/128
    fc00::/7
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  DEFAULT_RESOLVER = ->(host) { Resolv.getaddresses(host) }

  cattr_accessor :resolver

  class << self
    def validate!(url, allow_private: false)
      uri = URI.parse(url.to_s)
      unless %w[http https].include?(uri.scheme) && uri.host.present?
        raise BlockedUrlError, "URL must be a valid http or https URL"
      end

      addresses = resolve_addresses(uri.host)
      addresses.each do |address|
        if ALWAYS_BLOCKED_RANGES.any? { |range| range.include?(address) }
          raise BlockedUrlError, "#{uri.host} resolves to a blocked address (#{address})"
        end

        if !allow_private && PRIVATE_RANGES.any? { |range| range.include?(address) }
          raise BlockedUrlError, "#{uri.host} resolves to a private address (#{address})"
        end
      end

      ValidatedUrl.new(uri:, ipaddr: addresses.first.to_s)
    rescue URI::InvalidURIError => e
      raise BlockedUrlError, "Invalid URL: #{e.message}"
    end

    # Cheap check for IP literals and localhost, usable in model validations
    # without DNS lookups. Hostnames that merely resolve to private addresses
    # are caught at request time by validate!.
    def obviously_private_host?(host)
      return true if host.to_s.casecmp("localhost").zero?

      address = ip_literal(host)
      return false if address.nil?

      PRIVATE_RANGES.any? { |range| range.include?(address) } ||
        ALWAYS_BLOCKED_RANGES.any? { |range| range.include?(address) }
    end

    private

    def resolve_addresses(host)
      return [ IPAddr.new("127.0.0.1") ] if host.to_s.casecmp("localhost").zero?

      literal = ip_literal(host)
      return [ literal ] if literal

      addresses = (resolver || DEFAULT_RESOLVER).call(host).filter_map { |value| ip_literal(value) }
      raise BlockedUrlError, "Could not resolve #{host}" if addresses.empty?

      addresses
    end

    # IPv4-mapped/compat IPv6 forms (e.g. ::ffff:169.254.169.254) are
    # normalized to their native IPv4 address, since IPAddr ranges do not
    # match across address families.
    def ip_literal(value)
      address = IPAddr.new(value.to_s.delete_prefix("[").delete_suffix("]"))
      return address.native if address.ipv6? && (address.ipv4_mapped? || address.ipv4_compat?)

      address
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      nil
    end
  end
end
