# frozen_string_literal: true

require "test_helper"

class APITokenTest < ActiveSupport::TestCase
  test "issue! returns a raw token and stores only the digest" do
    token, raw = APIToken.issue!(
      name: "Bot",
      user: users(:one),
      scopes: %w[search:read requests:read]
    )

    assert_match(/\Ashf_/, raw)
    assert_equal raw.first(12), token.token_prefix
    assert_not_equal raw, token.token_digest
    assert_equal token, APIToken.authenticate(raw)
  end

  test "revoked tokens do not authenticate" do
    token, raw = APIToken.issue!(
      name: "Bot",
      user: users(:one),
      scopes: %w[search:read]
    )

    token.revoke!

    assert_nil APIToken.authenticate(raw)
  end

  test "rejects unknown scopes" do
    token = APIToken.new(
      name: "Bad",
      user: users(:one),
      scopes: [ "bad:scope" ].to_json,
      token_digest: APIToken.digest("raw"),
      token_prefix: "raw"
    )

    assert_not token.valid?
    assert token.errors[:scopes].any?
  end
end
