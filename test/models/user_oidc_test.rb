# frozen_string_literal: true

require "test_helper"

class UserOidcTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:oidc_auto_create_users, false)
    SettingsService.set(:oidc_link_existing_users, false)
    SettingsService.set(:oidc_default_role, "user")
  end

  test "oidc_user? returns true for OIDC users" do
    user = users(:one)
    user.update!(oidc_provider: "oidc", oidc_uid: "12345")

    assert user.oidc_user?
  end

  test "oidc_user? returns false for regular users" do
    user = users(:one)

    assert_not user.oidc_user?
  end

  test "from_oidc finds existing user by oidc identity" do
    user = users(:one)
    user.update!(oidc_provider: "oidc", oidc_uid: "existing-uid")

    auth_hash = {
      "provider" => "oidc",
      "uid" => "existing-uid",
      "info" => { "email" => "test@example.com" }
    }

    result = User.from_oidc(auth_hash)

    assert_equal user, result
  end

  test "from_oidc does not implicitly link existing user by email prefix" do
    user = User.create!(
      username: "johndoe",
      name: "John Doe",
      password: "ValidPassword123!"
    )

    auth_hash = {
      "provider" => "oidc",
      "uid" => "new-uid",
      "info" => { "email" => "johndoe@example.com" }
    }

    result = User.from_oidc(auth_hash)

    assert_nil result
    assert_not user.reload.oidc_user?
  end

  test "from_oidc links existing user by preferred_username when linking is enabled" do
    SettingsService.set(:oidc_link_existing_users, true)

    user = User.create!(
      username: "johndoe",
      name: "John Doe",
      password: "ValidPassword123!"
    )

    auth_hash = {
      "provider" => "oidc",
      "uid" => "new-uid",
      "info" => { "preferred_username" => "johndoe" }
    }

    result = User.from_oidc(auth_hash)

    assert_equal user, result
    assert_equal "oidc", user.reload.oidc_provider
    assert_equal "new-uid", user.oidc_uid
  end

  test "from_oidc links existing user by email prefix when linking is enabled" do
    SettingsService.set(:oidc_link_existing_users, true)

    user = User.create!(
      username: "johndoe",
      name: "John Doe",
      password: "ValidPassword123!"
    )

    auth_hash = {
      "provider" => "oidc",
      "uid" => "new-uid",
      "info" => { "email" => "johndoe@example.com" }
    }

    result = User.from_oidc(auth_hash)

    assert_equal user, result
    assert_equal "oidc", user.reload.oidc_provider
    assert_equal "new-uid", user.oidc_uid
  end

  test "from_oidc returns nil when user not found and auto-create disabled" do
    SettingsService.set(:oidc_auto_create_users, false)

    auth_hash = {
      "provider" => "oidc",
      "uid" => "unknown-uid",
      "info" => { "email" => "unknown@example.com", "name" => "Unknown" }
    }

    result = User.from_oidc(auth_hash)

    assert_nil result
  end

  test "from_oidc creates user when auto-create enabled" do
    SettingsService.set(:oidc_auto_create_users, true)

    auth_hash = {
      "provider" => "oidc",
      "uid" => "new-uid-123",
      "info" => {
        "email" => "newuser@example.com",
        "name" => "New User"
      }
    }

    assert_difference("User.count", 1) do
      result = User.from_oidc(auth_hash)

      assert_equal "newuser", result.username
      assert_equal "New User", result.name
      assert_equal "oidc", result.oidc_provider
      assert_equal "new-uid-123", result.oidc_uid
      assert_equal "user", result.role
    end
  end

  test "from_oidc creates admin when default role is admin" do
    SettingsService.set(:oidc_auto_create_users, true)
    SettingsService.set(:oidc_default_role, "admin")

    auth_hash = {
      "provider" => "oidc",
      "uid" => "admin-uid",
      "info" => {
        "email" => "admin@example.com",
        "name" => "Admin User"
      }
    }

    result = User.from_oidc(auth_hash)

    assert_equal "admin", result.role
  end

  test "from_oidc generates unique username when collision exists" do
    SettingsService.set(:oidc_auto_create_users, true)

    # Create user with same username that's already an OIDC user (so it won't be linked)
    User.create!(
      username: "testuser",
      name: "Existing",
      password: "ValidPassword123!",
      oidc_provider: "other-provider",
      oidc_uid: "different-uid"
    )

    auth_hash = {
      "provider" => "oidc",
      "uid" => "collision-uid",
      "info" => {
        "email" => "testuser@example.com",
        "name" => "Test User"
      }
    }

    result = User.from_oidc(auth_hash)

    assert_equal "testuser1", result.username
  end

  test "from_oidc sanitizes username from email" do
    SettingsService.set(:oidc_auto_create_users, true)

    auth_hash = {
      "provider" => "oidc",
      "uid" => "special-chars-uid",
      "info" => {
        "email" => "John.Doe+test@example.com",
        "name" => "John Doe"
      }
    }

    result = User.from_oidc(auth_hash)

    # Special characters should be replaced with underscores
    assert_match(/\A[a-z0-9_]+\z/, result.username)
  end

  test "from_oidc uses preferred_username when email not available" do
    SettingsService.set(:oidc_auto_create_users, true)

    auth_hash = {
      "provider" => "oidc",
      "uid" => "no-email-uid",
      "info" => {
        "preferred_username" => "preferred_user",
        "name" => "Preferred User"
      }
    }

    result = User.from_oidc(auth_hash)

    assert_equal "preferred_user", result.username
  end

  test "link_oidc_identity! links an unlinked user" do
    user = users(:one)

    user.link_oidc_identity!(provider: "oidc", uid: "linked-uid")

    assert_equal "oidc", user.reload.oidc_provider
    assert_equal "linked-uid", user.oidc_uid
  end

  test "link_oidc_identity! rejects identities already linked to another user" do
    existing = users(:two)
    existing.update!(oidc_provider: "oidc", oidc_uid: "shared-uid")

    error = assert_raises(User::OidcIdentityAlreadyLinkedError) do
      users(:one).link_oidc_identity!(provider: "oidc", uid: "shared-uid")
    end

    assert_match(/already linked/i, error.message)
  end

  test "link_oidc_identity! rejects replacing a different existing identity" do
    user = users(:one)
    user.update!(oidc_provider: "oidc", oidc_uid: "old-uid")

    error = assert_raises(User::OidcIdentityConflictError) do
      user.link_oidc_identity!(provider: "oidc", uid: "new-uid")
    end

    assert_match(/different OIDC identity/i, error.message)
  end
end
