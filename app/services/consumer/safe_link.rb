# frozen_string_literal: true

# A remote image or link a native app may fetch without credentials: HTTPS,
# with a host and no embedded user information. Anything else becomes nil.
module Consumer
  module SafeLink
    module_function

    def call(value)
      uri = parse(value.to_s)
      return nil if RemoteResult.failed?(uri)

      uri.to_s if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
    end

    def parse(value)
      URI.parse(value)
    rescue URI::InvalidURIError => error
      RemoteResult::Failed.new(error)
    end
  end
end
