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

  test "large Store cursors stay within a small proxy response header and survive a new cursor instance" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    store = SecureRandom.urlsafe_base64(3_000)
    token = @cursor.write(local: "saved-local", store: store)
    assert_operator token.bytesize, :<=, 3.kilobytes, "a normal 4 KiB proxy buffer must fit the cursor and other headers"
    assert_not_includes token, store
    reopened = Kobo::SyncCursor.new(@device.reload, authorization: "Bearer reader-own")
    assert_equal Kobo::SyncCursor::Parts.new(local: "saved-local", store: store), reopened.read(token)
    other_sign_in = Kobo::SyncCursor.new(@device, authorization: "Bearer other")
    assert_equal Kobo::SyncCursor::Parts.new(local: "saved-local", store: nil), other_sign_in.read(token)
    Rails.cache.clear
    assert_equal Kobo::SyncCursor::Parts.new(local: "saved-local", store: nil), reopened.read(token), "cache eviction replays only Store, preserving the local position"
  ensure
    Rails.cache = previous
  end

  test "an overflow reference stores only ciphertext and rejects swapped or damaged cache values" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    store = SecureRandom.urlsafe_base64(3_000)
    token = @cursor.write(local: "local", store: store)
    claims = @cursor.send(:encryptor).decrypt_and_verify(token.delete_prefix("sf2."), purpose: "kobo-sync-cursor")
    key = @cursor.send(:cache_key, claims.fetch("store_reference"))
    encrypted = Rails.cache.read(key)
    assert_not_includes encrypted, store
    assert_equal store, @cursor.read(token).store

    another = @cursor.write(local: "other-local", store: SecureRandom.urlsafe_base64(3_000))
    other_claims = @cursor.send(:encryptor).decrypt_and_verify(another.delete_prefix("sf2."), purpose: "kobo-sync-cursor")
    other_key = @cursor.send(:cache_key, other_claims.fetch("store_reference"))
    Rails.cache.write(key, Rails.cache.read(other_key))
    assert_equal Kobo::SyncCursor::Parts.new(local: "local", store: nil), @cursor.read(token)
    Rails.cache.write(key, "damaged ciphertext")
    assert_equal Kobo::SyncCursor::Parts.new(local: "local", store: nil), @cursor.read(token)
  ensure
    Rails.cache = previous
  end

  test "a cache failure never returns an oversized header or acknowledges an unstored continuation" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::NullStore.new
    assert_equal "short", @cursor.read(@cursor.write(local: "local", store: "short")).store
    assert_raises(Kobo::StoreProxy::Unavailable) { @cursor.write(local: "local", store: SecureRandom.urlsafe_base64(3_000)) }
  ensure
    Rails.cache = previous
  end

  test "an overflow reference expires without losing the local position and rotation still revokes it" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    token = @cursor.write(local: "local", store: SecureRandom.urlsafe_base64(3_000))
    travel_to(31.days.from_now) { assert_equal Kobo::SyncCursor::Parts.new(local: "local", store: nil), @cursor.read(token) }
    @device.rotate_token!
    assert_equal Kobo::SyncCursor::EMPTY, Kobo::SyncCursor.new(@device, authorization: "Bearer reader-own").read(token)
  ensure
    Rails.cache = previous
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
