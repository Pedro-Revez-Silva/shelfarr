# frozen_string_literal: true

require "test_helper"

class API::Consumer::V1::AuthControllerTest < ActionDispatch::IntegrationTest
  test "browser approval uses the existing signed-in account and returns only scoped expiring credentials to the device" do
    post "/api/consumer/v1/auth/device", params: { client_name: "My Android phone" }, as: :json
    assert_response :ok
    data = response.parsed_body
    assert_equal 600, data.fetch("expires_in")
    assert_equal 5, data.fetch("interval")
    assert_includes response.headers["Cache-Control"], "no-store"
    grant = ConsumerDeviceGrant.for_device_code(data.fetch("device_code"))
    assert_not_includes grant.attributes.values, data.fetch("device_code")
    assert_not_includes grant.attributes.values, data.fetch("user_code")

    get URI(data.fetch("verification_uri_complete")).request_uri
    assert_redirected_to new_session_path
    sign_in_as(users(:one))
    assert_no_difference "APIToken.count" do
      get consumer_connect_path(user_code: data.fetch("user_code"))
    end
    assert_select "body", text: /My Android phone/
    assert_select "body", text: /Only approve a connection you started yourself/
    post consumer_connect_path, params: { user_code: data.fetch("user_code"), decision: "allow" }
    assert_response :success
    assert_not_includes response.body, data.fetch("device_code")
    assert_no_difference "APIToken.count" do
      head consumer_connect_path(user_code: data.fetch("user_code"))
    end

    assert_difference "APIToken.count", 1 do
      post "/api/consumer/v1/auth/token", params: { device_code: data.fetch("device_code") }, as: :json
    end
    assert_response :ok
    token_data = response.parsed_body
    token = APIToken.authenticate(token_data.fetch("access_token"))
    assert_equal users(:one), token.user
    assert_equal %w[library:read progress:write], token.scope_list
    assert_in_delta 30.days.from_now, token.expires_at, 3
    assert_no_difference "APIToken.count" do
      post "/api/consumer/v1/auth/token", params: { device_code: data.fetch("device_code") }, as: :json
    end
    assert_response :bad_request
    assert_equal "expired_token", response.parsed_body.fetch("error")
  end

  test "polling backoff commits and expired denied or deleted accounts do not receive tokens" do
    grant, code, user_code = ConsumerDeviceGrant.issue!(client_name: "Phone")
    post "/api/consumer/v1/auth/token", params: { device_code: code }, as: :json
    assert_equal "authorization_pending", response.parsed_body.fetch("error")
    post "/api/consumer/v1/auth/token", params: { device_code: code }, as: :json
    assert_equal "slow_down", response.parsed_body.fetch("error")
    assert_equal 10, grant.reload.poll_interval
    sign_in_as(users(:one))
    post consumer_connect_path, params: { user_code: user_code, decision: "deny" }
    post "/api/consumer/v1/auth/token", params: { device_code: code }, as: :json
    assert_equal "access_denied", response.parsed_body.fetch("error")
    grant.update!(expires_at: 1.second.ago)
    post "/api/consumer/v1/auth/token", params: { device_code: code }, as: :json
    assert_equal "expired_token", response.parsed_body.fetch("error")

    second, second_code, = ConsumerDeviceGrant.issue!(client_name: "Second phone")
    second.decide!(actor: users(:one), allow: true)
    users(:one).update!(deleted_at: Time.current)
    assert_no_difference "APIToken.count" do
      post "/api/consumer/v1/auth/token", params: { device_code: second_code }, as: :json
    end
    assert_equal "access_denied", response.parsed_body.fetch("error")
  end

  test "approval requires a session and CSRF and never occurs on GET" do
    grant, _, code = ConsumerDeviceGrant.issue!(client_name: "Phone")
    post consumer_connect_path, params: { user_code: code, decision: "allow" }
    assert_response :redirect
    assert_nil grant.reload.approved_at
    sign_in_as(users(:one))
    get consumer_connect_path(user_code: code)
    assert_nil grant.reload.approved_at
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post consumer_connect_path, params: { user_code: code, decision: "allow" }
    assert_response :unprocessable_entity
    assert_nil grant.reload.approved_at
  ensure
    ActionController::Base.allow_forgery_protection = original unless original.nil?
  end

  test "malformed or oversized device requests fail without credentials or server errors" do
    [ nil, "", "x" * 81, {}, [] ].each do |name|
      post "/api/consumer/v1/auth/device", params: { client_name: name }, as: :json
      assert_response :bad_request
    end
    [ nil, {}, [], "not-a-code" ].each do |code|
      post "/api/consumer/v1/auth/token", params: { device_code: code }, as: :json
      assert_response :bad_request
    end
    post "/api/consumer/v1/auth/device", params: "x" * 65_537, headers: { "Content-Type" => "application/json" }
    assert_response :content_too_large
  end
end
