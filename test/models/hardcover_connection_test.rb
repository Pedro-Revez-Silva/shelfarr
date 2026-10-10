# frozen_string_literal: true

require "test_helper"

class HardcoverConnectionTest < ActiveSupport::TestCase
  setup { SettingsService.set(:hardcover_enabled, true) }

  test "tokens are encrypted at rest and filtered from inspection" do
    connection = create_hardcover_connection(users(:one), access_token: "hc_at_plain", refresh_token: "hc_rt_plain")

    raw = HardcoverConnection.connection.select_one("SELECT access_token, refresh_token FROM hardcover_connections WHERE id = #{connection.id}")
    assert_not_includes raw.values.join, "hc_at_plain"
    assert_not_includes raw.values.join, "hc_rt_plain"
    assert_equal "hc_at_plain", connection.reload.access_token
    assert_not_includes connection.inspect, "hc_at_plain"
  end

  test "a user has at most one connection" do
    create_hardcover_connection(users(:one))

    assert_raises(ActiveRecord::RecordNotUnique) do
      HardcoverConnection.create!(user: users(:one), auth_method: "personal_token", access_token: "x", hardcover_user_id: 1)
    end
  end

  test "is unusable when reauthorization is required, the user is deleted, or Hardcover is disabled" do
    connection = create_hardcover_connection(users(:one))
    assert connection.usable?

    SettingsService.set(:hardcover_enabled, false)
    assert_not connection.usable?
    SettingsService.set(:hardcover_enabled, true)

    connection.update!(status: "reauthorization_required")
    assert_not connection.usable?
  end

  test "requiring reauthorization pauses only subscriptions that need the account" do
    user = users(:one)
    connection = create_hardcover_connection(user)
    shelf = create_hardcover_subscription(user, kind: "want_to_read")
    author = create_hardcover_subscription(user, kind: "author", target_id: 3)

    connection.mark_reauthorization_required!("revoked")

    assert shelf.reload.paused?
    assert author.reload.active?
  end

  test "the credential spends from the account budget" do
    connection = create_hardcover_connection(users(:one), hardcover_user_id: 99)

    assert_equal HardcoverClient.credential_for_token("anything", budget_key: "account:99").digest, connection.credential.digest
  end
end
