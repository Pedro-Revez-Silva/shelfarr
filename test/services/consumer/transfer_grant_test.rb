# frozen_string_literal: true

require "test_helper"

class Consumer::TransferGrantTest < ActiveSupport::TestCase
  setup do
    @token, = APIToken.issue!(name: "Reader", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES)
    @book = Book.create!(title: "Granted", book_type: :ebook)
    @asset_id = "a" * 64
  end

  test "a grant is opaque and opens only its publication and asset for its live token" do
    grant, expires_at = issue
    assert_match Consumer::TransferGrant::FORMAT, grant
    assert_operator grant.length, :<=, 512
    assert_not_includes grant, @asset_id
    assert_not_includes grant, @token.token_digest
    assert_in_delta 24.hours.from_now, expires_at, 1.second
    assert_equal @token, verify(grant)
    assert_equal @token, Consumer::TransferGrant.verify(grant, book_id: @book.id, asset_id: @asset_id)
    assert_nil verify(grant, book_id: (@book.id + 1).to_s)
    assert_nil verify(grant, asset_id: "b" * 64)
    assert_not_equal grant, issue.first
  end

  test "the issuing token user and library scope must still be valid" do
    grant, = issue
    @token.update!(scopes: [ "library:read" ].to_json)
    assert_equal @token, verify(grant)
    @token.update!(scopes: [ "search:read", "progress:write" ].to_json)
    assert_nil verify(grant)
    @token.update!(scopes: ConsumerDeviceGrant::SCOPES.to_json)
    @token.revoke!
    assert_nil verify(grant)
    @token.update!(revoked_at: nil, expires_at: 1.second.ago)
    assert_nil verify(grant)
    @token.update!(expires_at: nil)
    users(:one).update!(deleted_at: Time.current)
    assert_nil verify(grant)
    users(:one).update!(deleted_at: nil)
    @token.update_columns(user_id: users(:two).id)
    assert_nil verify(grant)
    @token.update_columns(user_id: nil)
    assert_nil verify(grant)
  end

  test "lifetime is a day or the token's own expiry when sooner" do
    now = Time.utc(2026, 11, 7, 12)
    @token.update!(expires_at: now + 3.hours)
    _, expires_at = Consumer::TransferGrant.issue(api_token: @token, book: @book, asset_id: @asset_id, now: now)
    assert_equal now + 3.hours, expires_at
    @token.update!(expires_at: now + 30.days)
    grant, expires_at = Consumer::TransferGrant.issue(api_token: @token, book: @book, asset_id: @asset_id, now: now)
    assert_equal now + 24.hours, expires_at
    travel_to(now + 24.hours - 1.second) { assert_equal @token, verify(grant) }
    travel_to(now + 24.hours + 1.second) { assert_nil verify(grant) }
  end

  test "forged, re-purposed and malformed values are refused" do
    claims = { "t" => @token.id, "u" => @token.user_id, "b" => @book.id.to_s, "a" => @asset_id }
    encryptor = Consumer::TransferGrant.encryptor
    assert_equal @token, verify(encryptor.encrypt_and_sign(claims, purpose: Consumer::TransferGrant::PURPOSE))
    assert_nil verify(encryptor.encrypt_and_sign(claims, purpose: "consumer_library_cursor"))
    assert_nil verify(encryptor.encrypt_and_sign(claims))
    assert_nil verify(encryptor.encrypt_and_sign([ claims ], purpose: Consumer::TransferGrant::PURPOSE))
    assert_nil verify(encryptor.encrypt_and_sign(claims.merge("u" => users(:two).id), purpose: Consumer::TransferGrant::PURPOSE))
    other_key = ActiveSupport::MessageEncryptor.new(SecureRandom.bytes(32), cipher: "aes-256-gcm", serializer: :json, url_safe: true)
    assert_nil verify(other_key.encrypt_and_sign(claims, purpose: Consumer::TransferGrant::PURPOSE))
    signed = ActiveSupport::MessageVerifier.new(Rails.application.secret_key_base, serializer: :json, url_safe: true)
    assert_nil verify(signed.generate(claims, purpose: Consumer::TransferGrant::PURPOSE))
    grant, = issue
    [ nil, 42, [ grant ], "", "short", "#{grant}=", "#{grant} ", grant.reverse, grant[0..-2], "x" * 4096 ].each do |value|
      assert_nil verify(value), value.inspect.first(40)
    end
  end

  private

  def issue
    Consumer::TransferGrant.issue(api_token: @token, book: @book, asset_id: @asset_id)
  end

  def verify(grant, book_id: @book.id.to_s, asset_id: @asset_id)
    Consumer::TransferGrant.verify(grant, book_id: book_id, asset_id: asset_id)
  end
end
