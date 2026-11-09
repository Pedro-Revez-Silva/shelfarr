# frozen_string_literal: true

require "test_helper"

class Kobo::SyncCursorTest < ActiveSupport::TestCase
  setup do
    @device, = KoboDevice.issue(user: users(:one), name: "Reader", base_url: "https://shelfarr.example")
    @device.save!
    @cursor = Kobo::SyncCursor.new(@device, authorization: "Bearer reader-own")
  end

  test "both positions round-trip in an envelope that hides the Store cursor" do
    token = @cursor.write(local: "local-part", store: "kobo-account-cursor")
    assert token.start_with?("sf2.")
    assert_not_includes token, "kobo-account-cursor"
    assert_equal Kobo::SyncCursor::Parts.new(local: "local-part", store: "kobo-account-cursor"), @cursor.read(token)
  end

  test "an envelope from another reader, an old address or a tampered value restarts both positions" do
    token = @cursor.write(local: "local", store: "store")
    other, = KoboDevice.issue(user: users(:one), name: "Other", base_url: "https://shelfarr.example")
    other.save!
    assert_equal Kobo::SyncCursor::EMPTY, Kobo::SyncCursor.new(other).read(token)
    assert_equal Kobo::SyncCursor::EMPTY, @cursor.read(token.sub(/.\z/) { |c| c == "A" ? "B" : "A" })
    @device.rotate_token!
    assert_equal Kobo::SyncCursor::EMPTY, Kobo::SyncCursor.new(@device).read(token)
  end

  test "Shelfarr's earlier cursor stays local and is never mistaken for a Store cursor" do
    legacy = KoboSync.new(@device, endpoint: "https://shelfarr.example/kobo/x").call(nil).token
    assert_equal Kobo::SyncCursor::Parts.new(local: legacy, store: nil), @cursor.read(legacy)
    forged = "#{Base64.strict_encode64('{}')}--#{'0' * 64}"
    assert_nil @cursor.read(forged).store
  end

  test "unbound Store cursors are replayed instead of attached to an assumed account" do
    assert_equal Kobo::SyncCursor::EMPTY, @cursor.read("eyJTdG9yZSI6MX0")
    assert_equal Kobo::SyncCursor::EMPTY, @cursor.read("bad\r\nvalue")
    assert_equal Kobo::SyncCursor::EMPTY, @cursor.read("x" * (Kobo::SyncCursor::MAX_STORE_BYTES + 1))
    assert_equal Kobo::SyncCursor::EMPTY, @cursor.read(nil)
  end

  test "an unsafe Store cursor is dropped rather than stored" do
    assert_nil @cursor.read(@cursor.write(local: "l", store: "x" * (Kobo::SyncCursor::MAX_STORE_BYTES + 1))).store
  end

  test "changing the reader sign-in drops only the Store position" do
    token = @cursor.write(local: "local-progress", store: "account-A-position")
    other = Kobo::SyncCursor.new(@device, authorization: "Bearer account-B")
    assert_equal Kobo::SyncCursor::Parts.new(local: "local-progress", store: nil), other.read(token)
    assert_equal "account-A-position", @cursor.read(token).store
    assert_equal "local-progress", Kobo::SyncCursor.new(@device).read(token).local
    assert_nil Kobo::SyncCursor.new(@device).read(token).store
  end

  test "older encrypted envelopes retain local progress but cannot lend an unbound Store position" do
    claims = { "device" => @device.id, "generation" => @device.token_digest, "local" => "local", "store" => "unbound" }
    old = "sf2." + @cursor.send(:encryptor).encrypt_and_sign(claims, purpose: "kobo-sync-cursor")
    assert_equal Kobo::SyncCursor::Parts.new(local: "local", store: nil), @cursor.read(old)
  end
end
