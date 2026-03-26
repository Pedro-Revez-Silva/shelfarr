# frozen_string_literal: true

module DownloadClients
  class Decypharr < Qbittorrent
    private

    def adapter_specific_add_torrent_params
      { sequentialDownload: "true" }
    end

    def session_cookie_pattern
      /\b(?<name>SID|sid)=(?<value>[^;]+)/i
    end

    def default_session_cookie_name
      "sid"
    end
  end
end
