# frozen_string_literal: true

require "uri"

class MagnetLink
  BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

  def self.normalize_info_hash(value)
    extracted = info_hash(value)
    return extracted if extracted.is_a?(String)

    hex = value.to_s.strip.downcase
    hex if hex.match?(/\A[a-f0-9]{40}\z/)
  end

  # Extract the BitTorrent info hash from a magnet link.
  # Returns the 40-character lowercase hex hash, or nil when the link
  # doesn't carry a valid btih hash.
  def self.info_hash(url)
    query = magnet_query(url.to_s.strip)
    return nil unless query

    hashes = query.split("&").filter_map { |param| exact_topic_hash(param) }.uniq
    hashes.first if hashes.one?
  rescue ArgumentError => error
    RemoteResult::Failed.new(error)
  end

  def self.magnet_query(url)
    url = URI.decode_www_form_component(url) if url.match?(/\Amagnet%3A/i)
    url.sub(/\Amagnet:\?/i, "").split("#", 2).first.to_s if url.match?(/\Amagnet:\?/i)
  end
  private_class_method :magnet_query

  def self.exact_topic_hash(param)
    key, value = param.split("=", 2)
    return nil unless value && key.match?(/\A(?:x|%78)(?:t|%74)(?:\.\d+)?\z/i)

    hash = URI.decode_www_form_component(value)[/\Aurn:btih:([0-9a-f]{40}|[a-z2-7]{32})\z/i, 1]
    return nil unless hash
    return hash.downcase if hash.length == 40

    base32_to_hex(hash)
  end
  private_class_method :exact_topic_hash

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
