# frozen_string_literal: true

require "test_helper"

# Requesting is an explicit, browser-approved addition to an app connection.
class API::Consumer::V1::RequestPermissionTest < ActionDispatch::IntegrationTest
  REQUESTING = "library:read progress:write search:read requests:read requests:write"

  setup do
    @old_token, @old_raw = APIToken.issue!(name: "Shelfarr Android", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES,
      expires_at: 30.days.from_now, issued_via: APIToken::CONSUMER_DEVICE)
    @old_headers = { "Authorization" => "Bearer #{@old_raw}" }
  end

  test "an existing connection is upgraded only after explicit approval and keeps working until the new token is used" do
    post "/api/consumer/v1/auth/device", params: { client_name: "Shelfarr Android", scope: REQUESTING }, headers: @old_headers, as: :json
    assert_response :ok
    data = response.parsed_body
    grant = ConsumerDeviceGrant.for_device_code(data.fetch("device_code"))
    assert grant.upgrade?
    assert grant.requesting?

    sign_in_as(users(:one))
    get consumer_connect_path(user_code: data.fetch("user_code"))
    assert_select "h1", "Allow requesting from your app"
    assert_select "[data-consumer-approval=requesting]", text: /request ebooks and audiobooks as/
    assert_select "[data-consumer-approval=requesting]", text: /cannot see other people's requests, manage users or change server settings/
    assert_select "button[value=allow]", "Allow requesting"
    assert_select "button[value=deny]", "Not now"

    post consumer_connect_path, params: { user_code: data.fetch("user_code"), decision: "allow" }
    assert_response :success
    assert_select "h1", "Requesting allowed"

    post "/api/consumer/v1/auth/token", params: { device_code: data.fetch("device_code") }, as: :json
    assert_response :ok
    assert_equal REQUESTING, response.parsed_body.fetch("scope")
    new_raw = response.parsed_body.fetch("access_token")
    new_token = APIToken.find_by(token_digest: APIToken.digest(new_raw))
    assert new_token.consumer_device?
    assert_equal users(:one), new_token.user

    # A lost token response must not strand the app: the old credential still works.
    get "/api/consumer/v1/me", headers: @old_headers
    assert_response :success
    assert_not @old_token.reload.revoked?

    get "/api/consumer/v1/me", headers: { "Authorization" => "Bearer #{new_raw}" }
    assert_response :success
    assert_equal REQUESTING.split, response.parsed_body.fetch("scopes")
    assert @old_token.reload.revoked?
    get "/api/consumer/v1/me", headers: @old_headers
    assert_response :unauthorized
  end

  test "declining an upgrade leaves the existing read-only connection as it was" do
    post "/api/consumer/v1/auth/device", params: { client_name: "Shelfarr Android", scope: REQUESTING }, headers: @old_headers, as: :json
    data = response.parsed_body
    sign_in_as(users(:one))
    post consumer_connect_path, params: { user_code: data.fetch("user_code"), decision: "deny" }
    assert_select "h1", "Requesting not allowed"
    assert_no_difference "APIToken.count" do
      post "/api/consumer/v1/auth/token", params: { device_code: data.fetch("device_code") }, as: :json
    end
    assert_equal "access_denied", response.parsed_body.fetch("error")
    get "/api/consumer/v1/me", headers: @old_headers
    assert_response :success
    assert_equal ConsumerDeviceGrant::SCOPES, response.parsed_body.fetch("scopes")
    get "/api/consumer/v1/discover", params: { q: "dune" }, headers: @old_headers
    assert_response :forbidden
    assert_equal({ "error" => "insufficient_scope", "required_scope" => "search:read" }, response.parsed_body)
  end

  test "a different signed-in account cannot approve or decline another account's upgrade" do
    post "/api/consumer/v1/auth/device", params: { client_name: "Shelfarr Android", scope: REQUESTING }, headers: @old_headers, as: :json
    data = response.parsed_body
    grant = ConsumerDeviceGrant.for_device_code(data.fetch("device_code"))
    sign_in_as(users(:two))
    get consumer_connect_path(user_code: data.fetch("user_code"))
    assert_select "[data-consumer-approval=wrong-account]"
    assert_select "button[value=allow]", count: 0
    %w[allow deny].each do |decision|
      post consumer_connect_path, params: { user_code: data.fetch("user_code"), decision: decision }
      assert_response :forbidden
    end
    assert grant.reload.pending?
    assert_nil grant.user
  end

  test "old tokens never gain write scopes and scope requests are validated" do
    post "/api/consumer/v1/auth/device", params: { client_name: "Phone" }, as: :json
    grant = ConsumerDeviceGrant.for_device_code(response.parsed_body.fetch("device_code"))
    assert_equal ConsumerDeviceGrant::SCOPES, grant.granted_scopes
    assert_not grant.requesting?

    [ "requests:write", "library:read requests:admin", "users:write", "search:read requests:read", 7, [ "x" ] ].each do |scope|
      post "/api/consumer/v1/auth/device", params: { client_name: "Phone", scope: scope }, as: :json
      assert_response :bad_request, scope.inspect
      assert_equal "invalid_scope", response.parsed_body.fetch("error")
    end

    post "/api/consumer/v1/auth/device", params: { client_name: "Phone", scope: REQUESTING }, headers: { "Authorization" => "Bearer shf_not-a-real-token" }, as: :json
    assert_response :unauthorized
    @old_token.revoke!
    post "/api/consumer/v1/auth/device", params: { client_name: "Phone", scope: REQUESTING }, headers: @old_headers, as: :json
    assert_response :unauthorized
    assert_equal %w[library:read progress:write], @old_token.reload.scope_list
  end

  test "a fresh connection may opt in to requesting with explicit wording" do
    post "/api/consumer/v1/auth/device", params: { client_name: "Shelfarr iPad", scope: REQUESTING }, as: :json
    data = response.parsed_body
    sign_in_as(users(:one))
    get consumer_connect_path(user_code: data.fetch("user_code"))
    assert_select "h1", "Connect your Shelfarr app"
    assert_select "button[value=allow]", "Connect and allow requesting"
    post consumer_connect_path, params: { user_code: data.fetch("user_code"), decision: "allow" }
    post "/api/consumer/v1/auth/token", params: { device_code: data.fetch("device_code") }, as: :json
    assert_equal REQUESTING, response.parsed_body.fetch("scope")
  end

  test "device-approved credentials of an admin are never admin credentials on either API" do
    admin_token, raw = APIToken.issue!(name: "Admin phone", user: users(:two), scopes: ConsumerDeviceGrant::SCOPES + ConsumerDeviceGrant::REQUEST_SCOPES,
      issued_via: APIToken::CONSUMER_DEVICE)
    other = Request.create!(user: users(:one), book: Book.create!(title: "Someone else's", book_type: :ebook), status: :pending)
    headers = { "Authorization" => "Bearer #{raw}" }

    get "/api/v1/requests", headers: headers
    assert_response :success
    assert_not_includes response.parsed_body.fetch("requests").map { |request| request.fetch("id") }, other.id

    post "/api/v1/requests", params: { username: users(:one).username, work_id: "openlibrary:OL1W", book_type: "ebook", title: "On behalf" }, headers: headers
    assert_response :not_found

    post "/api/v1/requests/#{other.id}/retry", headers: headers
    assert_response :forbidden

    get "/api/consumer/v1/requests/#{other.id}", headers: headers
    assert_response :not_found
    assert admin_token.reload.consumer_device?
  end

  test "the server advertises requesting so apps can explain older servers" do
    get "/api/consumer/v1/server.json"
    assert_includes response.parsed_body.fetch("consumer_features"), "requests"
  end

  test "revoking the original connection invalidates its approved pending upgrade" do
    grant, device_code, = ConsumerDeviceGrant.issue!(client_name: "Phone", scope: REQUESTING, replaces: @old_token)
    grant.decide!(actor: users(:one), allow: true)

    post "/api/consumer/v1/auth/revoke", headers: @old_headers
    assert_response :no_content
    assert_no_difference "APIToken.count" do
      post "/api/consumer/v1/auth/token", params: { device_code: device_code }, as: :json
    end
    assert_response :bad_request
    assert_equal "access_denied", response.parsed_body.fetch("error")
    assert_nil APIToken.authenticate(@old_raw)
  end

  test "profile revocation removes issued upgrades before and after adoption without affecting other connections" do
    [ false, true ].each do |adopted|
      original, original_raw = APIToken.issue!(name: "Phone", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES)
      # Simulate a connection made before lineage existed.
      original.update!(connection_key: nil)
      replacement, replacement_raw = APIToken.issue!(name: "Phone", user: users(:one), scopes: REQUESTING.split,
        replaces: original, issued_via: APIToken::CONSUMER_DEVICE)
      unrelated, unrelated_raw = APIToken.issue!(name: "Other device", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES)
      assert replacement.connection_key.present?
      assert_equal original.reload.connection_key, replacement.connection_key
      assert APIToken.authenticate(replacement_raw) if adopted
      assert_nil replacement.reload.replaces_api_token_id if adopted
      sign_in_as(users(:one))
      delete api_token_profile_path(original)
      assert_response :redirect
      assert original.reload.revoked?
      assert replacement.reload.revoked?
      assert_nil APIToken.authenticate(original_raw)
      assert_nil APIToken.authenticate(replacement_raw)
      assert APIToken.authenticate(unrelated_raw)
      assert_not unrelated.reload.revoked?
    end
  end

  test "a revoked or expired origin cannot issue a replacement even after approval" do
    [ { revoked_at: Time.current }, { expires_at: 1.second.ago } ].each do |change|
      original, = APIToken.issue!(name: "Phone", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES)
      grant, code, = ConsumerDeviceGrant.issue!(client_name: "Phone", scope: REQUESTING, replaces: original)
      grant.decide!(actor: users(:one), allow: true)
      # Bypass revoke!'s proactive invalidation to prove exchange independently
      # refuses an origin that becomes unusable between approval and polling.
      original.update!(change)
      assert_no_difference "APIToken.count" do
        post "/api/consumer/v1/auth/token", params: { device_code: code }, as: :json
      end
      assert_equal "access_denied", response.parsed_body.fetch("error")
      assert_raises(APIToken::InactiveReplacement) do
        APIToken.issue!(name: "Invalid replacement", user: users(:one), scopes: REQUESTING.split, replaces: original)
      end
    end
  end

  test "adoption rechecks an origin revoked after the replacement credential was looked up" do
    replacement, = APIToken.issue!(name: "Phone", user: users(:one), scopes: REQUESTING.split, replaces: @old_token)
    @old_token.revoke!
    assert_not replacement.retire_replaced_token!
    assert replacement.reload.revoked?
  end

  test "simultaneous lookups of one replacement remain valid after another request adopts it" do
    replacement, raw = APIToken.issue!(name: "Phone", user: users(:one), scopes: REQUESTING.split, replaces: @old_token)
    second_lookup = APIToken.find(replacement.id)
    assert APIToken.authenticate(raw)
    assert second_lookup.retire_replaced_token!
    assert APIToken.authenticate(raw)
    assert @old_token.reload.revoked?
  end
end
