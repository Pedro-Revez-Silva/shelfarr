# frozen_string_literal: true

require "test_helper"

class MagnetLinkTest < ActiveSupport::TestCase
  test "recognises magnet links and rejects other strings" do
    assert MagnetLink.parse("magnet:?xt=urn:btih:#{'a' * 40}").magnet?
    assert_not MagnetLink.parse("https://example.com/x.torrent").magnet?
    assert_not MagnetLink.parse("").magnet?
    assert_not MagnetLink.parse(nil).magnet?
  end

  test "returns the lowercased hex info hash" do
    hash = "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"
    assert_equal hash.downcase, MagnetLink.parse("magnet:?xt=urn:btih:#{hash}").info_hash
  end

  test "converts a base32 info hash to canonical hex" do
    # 32 'A's (base32) -> 20 zero bytes -> 40 hex zeros
    assert_equal "0" * 40, MagnetLink.parse("magnet:?xt=urn:btih:#{'A' * 32}").info_hash
  end

  test "returns nil for a malformed or truncated hash" do
    assert_nil MagnetLink.parse("magnet:?xt=urn:btih:abc").info_hash
    assert_nil MagnetLink.parse("magnet:?dn=No+Hash").info_hash
  end

  test "reads the xt parameter, not a hash embedded in another field" do
    real = "d" * 40
    decoy = "0" * 40
    magnet = "magnet:?dn=urn:btih:#{decoy}&xt=urn:btih:#{real}"

    assert_equal real, MagnetLink.parse(magnet).info_hash
  end

  test "picks the btih xt when multiple xt values are present" do
    real = "d" * 40
    magnet = "magnet:?xt=urn:btmh:1220abcd&xt=urn:btih:#{real}"

    assert_equal real, MagnetLink.parse(magnet).info_hash
  end

  test "extracts the display name from dn" do
    magnet = "magnet:?xt=urn:btih:#{'a' * 40}&dn=The+Perfect+Run"
    assert_equal "The Perfect Run", MagnetLink.parse(magnet).display_name
  end

  test "display name is nil when dn is absent" do
    assert_nil MagnetLink.parse("magnet:?xt=urn:btih:#{'a' * 40}").display_name
  end
end
