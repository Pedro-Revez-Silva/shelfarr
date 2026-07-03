# frozen_string_literal: true

require "uri"

class MagnetLink
  BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

  # Extract the BitTorrent info hash from a magnet link.
  # Returns the 40-character lowercase hex hash, or nil when the link
  # doesn't carry a valid btih hash.
  def self.info_hash(url)
    decoded_url = URI.decode_www_form_component(url.to_s)
    match = decoded_url.match(/btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i)
    return nil unless match

    hash = match[1]
    return hash.downcase if hash.match?(/\A[a-fA-F0-9]{40}\z/)

    base32_to_hex(hash)
  rescue ArgumentError
    nil
  end

  def self.base32_to_hex(value)
    bits = value.upcase.each_char.map do |char|
      index = BASE32_ALPHABET.index(char)
      return nil unless index

      index.to_s(2).rjust(5, "0")
    end.join

    bytes = bits.scan(/.{8}/).map { |byte| byte.to_i(2) }
    return nil unless bytes.length == 20

    bytes.pack("C*").unpack1("H*")
  end
  private_class_method :base32_to_hex
end
