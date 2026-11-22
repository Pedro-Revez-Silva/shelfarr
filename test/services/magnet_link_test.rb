# frozen_string_literal: true

require "test_helper"

class MagnetLinkTest < ActiveSupport::TestCase
  test "extracts hex info hash" do
    hash = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    magnet = "magnet:?xt=urn:btih:#{hash.upcase}&dn=Example"

    assert_equal hash, MagnetLink.info_hash(magnet)
  end

  test "converts base32 info hash to hex" do
    assert_equal "aa" * 20, MagnetLink.info_hash("magnet:?xt=urn:btih:#{'VK' * 16}")
  end

  test "extracts hash from url-encoded magnet" do
    hash = "b" * 40
    encoded = CGI.escape("magnet:?xt=urn:btih:#{hash}")

    assert_equal hash, MagnetLink.info_hash(encoded)
  end

  test "normalizes a bare info hash and ignores other ids" do
    hash = "ab" * 20

    assert_equal hash, MagnetLink.normalize_info_hash("  #{hash.upcase}  ")
    assert_equal hash, MagnetLink.normalize_info_hash("magnet:?xt=urn:btih:#{hash}&dn=Book")
    assert_nil MagnetLink.normalize_info_hash("SABnzbd_nzo_#{hash[0, 12]}")
    assert_nil MagnetLink.normalize_info_hash("abc123def456")
    assert_nil MagnetLink.normalize_info_hash(nil)
  end

  test "reads the hash only from the exact topic of a magnet link" do
    real = "ab" * 20
    decoy = "cd" * 20

    assert_equal real, MagnetLink.info_hash("magnet:?dn=btih:#{decoy}&xt=urn:btih:#{real}")
    assert_equal real, MagnetLink.info_hash("magnet:?dn=Book&xt.1=urn:btih:#{real.upcase}&tr=http://t.example/announce")
    assert_nil MagnetLink.info_hash("magnet:?xt=urn:sha1:#{real}&dn=urn:btih:#{decoy}")
    assert_nil MagnetLink.info_hash("magnet:?xt=urn:btih:#{real}0&dn=Book")
    assert_nil MagnetLink.info_hash("magnet:?xt=urn:btih:#{real}&xt=urn:btih:#{decoy}")
  end

  test "reads the exact topic from the query and not the fragment" do
    hash = "ab" * 20

    assert_equal hash, MagnetLink.info_hash("magnet:?xt=urn:btih:#{hash}#section")
    assert_equal hash, MagnetLink.info_hash("magnet:?%78t=urn:btih:#{hash}&dn=Book")
    assert_nil MagnetLink.info_hash("magnet:?dn=Book#section&xt=urn:btih:#{hash}")
    assert_equal hash, MagnetLink.info_hash("magnet:?%ZZ=1&xt=urn:btih:#{hash}")
  end

  test "converts a declared base32 exact topic to the same hex identity" do
    hex = "aa" * 20
    base32 = "VK" * 16

    assert_equal hex, MagnetLink.info_hash("magnet:?xt=urn:btih:#{base32.downcase}&dn=Book")
    assert_equal hex, MagnetLink.info_hash("magnet:?xt=urn:btih:#{hex}&xt=urn:btih:#{base32}")
  end

  test "finds no hash in an HTTP link that mentions one" do
    hash = "ab" * 20

    assert_nil MagnetLink.info_hash("https://indexer.example/download?title=urn:btih:#{hash}")
    assert_nil MagnetLink.info_hash("https://indexer.example/magnet:?xt=urn:btih:#{hash}")
    assert_nil MagnetLink.normalize_info_hash("https://indexer.example/get?link=#{CGI.escape("magnet:?xt=urn:btih:#{hash}")}")
    assert_nil MagnetLink.normalize_info_hash("Book btih:#{hash}")
  end

  test "returns nil when no valid hash is present" do
    assert_nil MagnetLink.info_hash("magnet:?dn=No+Hash")
    assert_nil MagnetLink.info_hash("magnet:?xt=urn:btih:tooshort")
    assert_nil MagnetLink.info_hash(nil)
    assert_nil MagnetLink.info_hash("")
  end
end
