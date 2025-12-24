require "test_helper"

class UserTest < ActiveSupport::TestCase
  # Use a password that meets all requirements: 12+ chars, uppercase, lowercase, number
  VALID_PASSWORD = "Password123!".freeze

  test "downcases and strips username" do
    user = User.new(username: " MYUSER ")
    assert_equal("myuser", user.username)
  end

  test "validates username format" do
    user = User.new(name: "Test", username: "invalid user!", password: VALID_PASSWORD)
    assert_not user.valid?
    assert user.errors[:username].any?
  end

  test "allows valid username characters" do
    user = User.new(name: "Test", username: "valid_user123", password: VALID_PASSWORD)
    assert user.valid?
  end

  test "validates password minimum length" do
    user = User.new(name: "Test", username: "testuser", password: "Short1")
    assert_not user.valid?
    assert user.errors[:password].any?
  end

  test "validates password complexity" do
    # Missing uppercase
    user = User.new(name: "Test", username: "testuser", password: "password12345")
    assert_not user.valid?
    assert user.errors[:password].any?

    # Missing lowercase
    user = User.new(name: "Test", username: "testuser", password: "PASSWORD12345")
    assert_not user.valid?

    # Missing number
    user = User.new(name: "Test", username: "testuser", password: "PasswordOnly!")
    assert_not user.valid?
  end

  test "locked? returns true when locked_until is in future" do
    user = users(:one)
    user.locked_until = 1.hour.from_now
    assert user.locked?
  end

  test "locked? returns false when locked_until is in past" do
    user = users(:one)
    user.locked_until = 1.hour.ago
    assert_not user.locked?
  end

  test "record_failed_login increments count and locks after threshold" do
    user = users(:one)
    user.update!(failed_login_count: 4)

    user.record_failed_login!("127.0.0.1")

    assert_equal 5, user.failed_login_count
    assert user.locked?
    assert_equal "127.0.0.1", user.last_failed_login_ip
  end

  test "reset_failed_logins clears lockout state" do
    user = users(:one)
    user.update!(
      failed_login_count: 5,
      locked_until: 1.hour.from_now,
      last_failed_login_ip: "127.0.0.1"
    )

    user.reset_failed_logins!

    assert_equal 0, user.failed_login_count
    assert_nil user.locked_until
    assert_nil user.last_failed_login_ip
  end
end
