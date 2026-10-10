# frozen_string_literal: true

module Hardcover
  # Chooses and maintains the credential for a Hardcover read.
  #
  # Personal data (Want to Read, private lists) is only ever read with the
  # owner's own connection. Public catalog data and public lists use the
  # instance token when one is configured, falling back to the viewer's own
  # connection so their usage lands on their own Hardcover budget.
  module Credentials
    class Unavailable < StandardError; end

    class << self
      def with_connection(connection)
        raise Unavailable, "Connect your Hardcover account first." unless connection&.usable?

        refresh_if_expiring!(connection)
        begin
          yield connection.credential
        rescue HardcoverClient::ScopeError
          raise
        rescue HardcoverClient::AuthenticationError => e
          raise unless connection.refreshable?

          # A 401 before the recorded expiry usually means Hardcover revoked
          # or rotated the token early. Refresh once, then give up.
          refresh!(connection, force: true)
          begin
            yield connection.credential
          rescue HardcoverClient::ScopeError
            raise
          rescue HardcoverClient::AuthenticationError
            connection.mark_reauthorization_required!("Hardcover rejected the connection: #{e.message}")
            raise
          end
        end
      rescue HardcoverClient::AuthenticationError => e
        if connection&.persisted? && connection.active? && !e.is_a?(HardcoverClient::ScopeError)
          connection.mark_reauthorization_required!("Hardcover rejected the connection: #{e.message}")
        end
        raise
      end

      def with_catalog(user: nil, &block)
        if HardcoverClient.configured?
          yield HardcoverClient.instance_credential
        elsif (connection = user&.hardcover_connection)&.usable?
          with_connection(connection, &block)
        else
          raise Unavailable, "Hardcover is not configured."
        end
      end

      def catalog_available?(user: nil)
        return false unless HardcoverIntegration.enabled?

        HardcoverClient.configured? || user&.hardcover_connection&.usable? == true
      end

      private

      def refresh_if_expiring!(connection)
        refresh!(connection) if connection.refreshable? && connection.access_token_expiring?
      end

      def refresh!(connection, force: false)
        Hardcover::Oauth.refresh_connection!(connection, force: force)
      rescue Hardcover::Oauth::AuthorizationError => e
        connection.mark_reauthorization_required!("Hardcover sign-in expired (#{e.message}). Connect again.")
        raise HardcoverClient::AuthenticationError, "Hardcover sign-in expired; reconnect your account"
      rescue Hardcover::Oauth::Error => e
        raise HardcoverClient::ConnectionError, e.message
      end
    end
  end
end
