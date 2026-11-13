# frozen_string_literal: true

# This server's public HTTPS base address (with any deployment subpath), as
# handed to the Android app in shelfarr://connect?server=... Only a clean
# HTTPS address qualifies: no credentials, query, fragment or dot segments.
class AndroidServerAddress
  CONNECT_URL = "shelfarr://connect"
  LABEL = /[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?/
  HOST = /\A(?:#{LABEL}(?:\.#{LABEL})*|\[[0-9A-Fa-f:.]+\])\z/

  def initialize(request)
    @scheme = request.scheme
    @host = request.host.to_s.downcase
    @port = request.port
    @path = request.script_name.to_s
  end

  def usable?
    @scheme == "https" && @host.match?(HOST) && (@path.empty? || AndroidUpdates::SourcePolicy.clean_path?(@path))
  end

  def to_s
    return "" unless usable?

    "https://#{@host}#{@port == 443 ? '' : ":#{@port}"}#{@path}"
  end

  def connect_url
    "#{CONNECT_URL}?server=#{ERB::Util.url_encode(to_s)}" if usable?
  end
end
