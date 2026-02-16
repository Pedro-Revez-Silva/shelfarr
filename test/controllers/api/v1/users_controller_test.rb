require "test_helper"

class API::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    SettingsService.set(:api_token, "apitoken")
  end

  test "create user" do
    assert_difference("User.count", 1) do
      post api_v1_users_path,
        headers: {
          "Authorization" => "Bearer apitoken"
        },
        params: {
          name: "John Doe",
          username: "johndoe",
          password: "Password1234"
        }
    end

    assert_response :created

    body = JSON.parse(response.body)
    assert_equal "johndoe", body["username"]
    assert_equal "John Doe", body["name"]
    assert body["id"].present?
  end

  test "returns error with missing field" do
    post api_v1_users_path,
      headers: {
        "Authorization" => "Bearer apitoken"
      },
      params: {
        name: "John Doe",
        username: "johndoe"
      }

    assert_response :unprocessable_entity

    body = JSON.parse(response.body)
    assert_equal [ "Password can't be blank" ], body["errors"]
  end

  test "ignores role parameter and creates regular user" do
    post api_v1_users_path,
      headers: {
        "Authorization" => "Bearer apitoken"
      },
      params: {
        name: "John Doe",
        username: "johndoe_user_role",
        password: "Password1234",
        role: "admin"
      }

    assert_response :created

    body = JSON.parse(response.body)
    assert_equal "user", body["role"]
  end

  test "returns error when invalid JSON payload" do
    post api_v1_users_path,
      headers: {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "Authorization" => "Bearer apitoken"
      },
      params: '{"name": "John",}'

    assert_response :bad_request

    body = JSON.parse(response.body)
    assert_equal [ "JSON invalid" ], body["errors"]
  end
end
