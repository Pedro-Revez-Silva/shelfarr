require "test_helper"

class API::V1::ApplicationControllerTest < ActionDispatch::IntegrationTest
  setup do
    SettingsService.set(:api_token, "apitoken")
  end

  test "returns unauthorized when auth token missing" do
    post api_v1_users_path

    assert_response :unauthorized
  end

  test "returns unauthorized when auth token malformed" do
    post api_v1_users_path,
      headers: {
        "Authorization" => "apitoken"
      }

    assert_response :unauthorized
  end

  test "return unauthorized when auth token incorrect" do
    post api_v1_users_path,
      headers: {
        "Authorization" => "Bearer invalidtoken"
      }

    assert_response :unauthorized
  end

  test "returns unauthorized for a token whose user was soft deleted" do
    user = users(:one)
    _token, raw_token = APIToken.issue!(
      name: "Deleted account token",
      user: user,
      scopes: %w[users:write]
    )
    user.soft_delete!

    assert_no_difference "User.count" do
      post api_v1_users_path,
        headers: { "Authorization" => "Bearer #{raw_token}" },
        params: {
          name: "Created by deleted account",
          username: "deleted_account_create",
          password: "Password123!"
        }
    end

    assert_response :unauthorized
  end

  test "privileged token scopes stop authorizing after admin demotion" do
    admin = users(:two)
    _token, raw_token = APIToken.issue!(
      name: "Former admin token",
      user: admin,
      scopes: %w[users:write]
    )
    admin.update!(role: :user)

    assert_no_difference "User.count" do
      post api_v1_users_path,
        headers: { "Authorization" => "Bearer #{raw_token}" },
        params: {
          name: "Created by former admin",
          username: "former_admin_create",
          password: "Password123!"
        }
    end

    assert_response :forbidden
  end
end
