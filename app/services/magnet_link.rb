# frozen_string_literal: true

require "uri"

# Parses a magnet: URI into its useful parts. Centralizes info-hash extraction
# and canonicalization (hex passes through, base32 is converted to hex) so
# callers dedupe on a stable key and validate hashes consistently rather than
# each reimplementing magnet parsing.
class MagnetLink
  # A v1 btih is either 40 hex chars or a 32-char base32 string.
  BTIH_REGEX = /\Aurn:btih:([a-f0-9]{40}|[a-z2-7]{32})\z/i
  BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

  def self.parse(value)
    new(value)
  end

  def initialize(value)
    @raw = value.to_s.strip
  end

  def url
    @raw
  end

  def magnet?
    @raw.downcase.start_with?("magnet:?")
  end

  # Canonical lowercase hex info hash, or nil if absent/invalid. Reads the
  # decoded `xt` parameters (a magnet may carry several) rather than scanning
  # the raw string, so a hash embedded in another field (e.g. `dn`) can't be
  # mistaken for the real one.
  def info_hash
    xt_values.each do |xt|
      match = xt.match(BTIH_REGEX)
      next unless match

      hash = match[1]
      return hash.downcase if hash.match?(/\A[a-f0-9]{40}\z/i)

      hex = base32_to_hex(hash)
      return hex if hex
    end
    nil
  end

  def display_name
    pairs.find { |key, _| key == "dn" }&.last.presence
  end

  private

  def xt_values
    pairs.filter_map { |key, value| value if key == "xt" }
  end

  def pairs
    @pairs ||= begin
      query = @raw.split("?", 2)[1].to_s
      URI.decode_www_form(query)
    rescue ArgumentError
      []
    end
  end

  def base32_to_hex(value)
    bits = value.upcase.each_char.map do |char|
      index = BASE32_ALPHABET.index(char)
      return nil unless index

      index.to_s(2).rjust(5, "0")
    end.join

    bytes = bits.scan(/.{8}/).map { |byte| byte.to_i(2) }
    return nil unless bytes.length == 20

    bytes.pack("C*").unpack1("H*")
  end
end
