# frozen_string_literal: true

# What a native app may learn about this server before it signs in.
module Consumer
  module ServerInfo
    # Consumer API generations this server implements. Independent of the
    # server's and the apps' release labels.
    API_VERSIONS = [ 1 ].freeze

    module_function

    def server_version
      path = Rails.root.join("VERSION")
      value = File.exist?(path) ? File.read(path, 64).to_s.strip : ""
      value.match?(/\A[0-9A-Za-z][0-9A-Za-z._+-]{0,63}\z/) ? value : "unknown"
    end
  end
end
