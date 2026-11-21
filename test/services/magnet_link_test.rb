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

  test "returns nil when no valid hash is present" do
    assert_nil MagnetLink.info_hash("magnet:?dn=No+Hash")
    assert_nil MagnetLink.info_hash("magnet:?xt=urn:btih:tooshort")
    assert_nil MagnetLink.info_hash(nil)
    assert_nil MagnetLink.info_hash("")
  end
end
