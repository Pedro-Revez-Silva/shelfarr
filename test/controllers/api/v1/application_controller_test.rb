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
end
