# frozen_string_literal: true

require "uri"

module AndroidUpdates
  # Where the server may fetch Android catalogs and APKs from.
  #
  # The official publisher lives on GitHub releases: APKs must be release
  # assets of the Shelfarr repository, and only GitHub's own release-asset
  # hosts may be redirected to. A custom catalog keeps every request, including
  # redirects, on its exact HTTPS origin.
  class SourcePolicy
    GITHUB_HOST = "github.com"
    GITHUB_RELEASE_PREFIX = "/Pedro-Revez-Silva/shelfarr/releases/download/"
    GITHUB_ASSET_HOSTS = %w[
      objects.githubusercontent.com
      release-assets.githubusercontent.com
    ].freeze
    ENCODED_SEPARATOR = /%(?:2e|2f|5c|00)/i

    def self.clean_https?(uri, allow_query: false)
      return false unless uri.is_a?(URI::HTTPS) && uri.host.present?
      return false if uri.userinfo || uri.fragment || (!allow_query && uri.query)

      clean_path?(uri.path)
    end

    def self.clean_path?(path)
      return false unless path.start_with?("/") && !path.include?("\\")
      return false if path.match?(ENCODED_SEPARATOR)

      path.split("/", -1).drop(1).none? { |segment| segment.empty? || segment == "." || segment == ".." }
    end

    def initialize(catalog_uri, default_source:)
      @catalog_uri = catalog_uri
      @default_source = default_source
    end

    def default_source?
      @default_source
    end

    # Self-hosted publishers may sit on the operator's own network. The
    # official one never does.
    def allow_private_network?
      !default_source?
    end

    def allowed_catalog?(uri)
      same_uri?(uri, @catalog_uri)
    end

    # An apk_url as written in the catalog: no query, an .apk path.
    def allowed_artifact?(uri)
      return false unless self.class.clean_https?(uri) && uri.path.end_with?(".apk")

      default_source? ? github_release_asset?(uri) : same_origin?(uri)
    end

    # A redirect from an allowed request. Signed asset URLs carry a query.
    def allowed_redirect?(uri)
      return false unless self.class.clean_https?(uri, allow_query: true)

      if default_source?
        github_release_asset?(uri) || (GITHUB_ASSET_HOSTS.include?(uri.host.downcase) && uri.port == 443)
      else
        same_origin?(uri)
      end
    end

    private

    def github_release_asset?(uri)
      uri.host.casecmp?(GITHUB_HOST) && uri.port == 443 && uri.path.start_with?(GITHUB_RELEASE_PREFIX)
    end

    def same_origin?(uri)
      uri.host.casecmp?(@catalog_uri.host) && uri.port == @catalog_uri.port
    end

    def same_uri?(uri, other)
      self.class.clean_https?(uri) && same_origin?(uri) && uri.path == other.path
    end
  end
end
