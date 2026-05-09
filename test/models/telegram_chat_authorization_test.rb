# frozen_string_literal: true

require "test_helper"

class TelegramChatAuthorizationTest < ActiveSupport::TestCase
  test "issue creates a pending authorization with a six digit code" do
    authorization, code = TelegramChatAuthorization.issue!(
      chat_id: "-100123",
      chat_title: "Readers",
      requested_by_telegram_user_id: "42",
      requested_by_telegram_username: "telegramuser"
    )

    assert_match(/\A\d{6}\z/, code)
    assert_equal "-100123", authorization.chat_id
    assert_equal "Readers", authorization.chat_title
    assert_equal "42", authorization.requested_by_telegram_user_id
    assert_not authorization.approved?
    assert authorization.code_valid?(code)
  end

  test "approve_code approves a valid pending code and clears code state" do
    authorization, code = TelegramChatAuthorization.issue!(
      chat_id: "-100123",
      chat_title: "Readers",
      requested_by_telegram_user_id: "42",
      requested_by_telegram_username: "telegramuser"
    )

    approved = TelegramChatAuthorization.approve_code!(code, approved_by: users(:two))

    assert_equal authorization, approved
    assert approved.approved?
    assert_equal users(:two), approved.approved_by
    assert_nil approved.code_digest
    assert_nil approved.code_generated_at
  end

  test "pause and resume control whether an approved group is enabled" do
    authorization = TelegramChatAuthorization.create!(
      chat_id: "-100123",
      chat_title: "Readers",
      approved_at: Time.current,
      approved_by: users(:two)
    )

    assert authorization.enabled?

    authorization.pause!
    assert authorization.paused?
    assert_not authorization.enabled?

    authorization.resume!
    assert_not authorization.paused?
    assert authorization.enabled?
  end

  test "approve_code rejects invalid and expired codes" do
    authorization, _code = TelegramChatAuthorization.issue!(
      chat_id: "-100123",
      chat_title: "Readers",
      requested_by_telegram_user_id: "42",
      requested_by_telegram_username: "telegramuser"
    )
    authorization.update!(code_generated_at: (TelegramChatAuthorization::CODE_TTL + 1.second).ago)

    assert_nil TelegramChatAuthorization.approve_code!("000000", approved_by: users(:two))
    assert_not authorization.reload.approved?
    assert authorization.expired?
  end
end
