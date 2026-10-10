# frozen_string_literal: true

require "test_helper"

# Per-account credentials, shared rate budgets, and Hardcover's documented
# error responses (https://docs.hardcover.app/api/getting-started).
class HardcoverClientAccountsTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    HardcoverClient.reset_connection!
    HardcoverClient.send(:local_rate_limit_deadlines).clear
  end

  teardown do
    HardcoverClient.send(:local_rate_limit_deadlines).clear
    HardcoverClient.reset_connection!
    Rails.cache = @original_cache
  end

  test "execute sends the given credential instead of the instance token" do
    SettingsService.set(:hardcover_api_token, "instance_token")
    credential = HardcoverClient.credential_for_token("hc_at_user", budget_key: HardcoverClient.account_budget_key(7))
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 7, "username" => "reader" } ] })

    HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential)

    assert_equal "Bearer hc_at_user", hardcover_requests.last[:authorization]
  end

  test "tokens of the same Hardcover account share one rate budget" do
    old_token = HardcoverClient.credential_for_token("hc_at_old", budget_key: HardcoverClient.account_budget_key(7))
    refreshed = HardcoverClient.credential_for_token("hc_at_new", budget_key: HardcoverClient.account_budget_key(7))
    other_account = HardcoverClient.credential_for_token("hc_at_other", budget_key: HardcoverClient.account_budget_key(8))
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(status: 429, headers: { "Retry-After" => "120" }, body: { error: "Too Many Requests" }.to_json)

    assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: old_token) }

    error = assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: refreshed) }
    assert_operator error.retry_after, :>, 100
    assert_requested :post, HardcoverClient::BASE_URL, times: 1

    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { data: { me: [ { id: 8 } ] } }.to_json)
    assert HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: other_account)
  end

  test "different tokens on one account never reuse each other's authorization header" do
    first = HardcoverClient.credential_for_token("hc_at_first", budget_key: HardcoverClient.account_budget_key(9))
    second = HardcoverClient.credential_for_token("hc_at_second", budget_key: HardcoverClient.account_budget_key(9))
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 9 } ] })

    HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: first)
    HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: second)

    assert_equal [ "Bearer hc_at_first", "Bearer hc_at_second" ], hardcover_requests.map { |request| request[:authorization] }
  end

  test "a missing scope raises ScopeError with the scope Hardcover reported" do
    credential = HardcoverClient.credential_for_token("hc_at_scoped")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(
      status: 403, headers: { "Content-Type" => "application/json" },
      body: { error: "insufficient_scope", error_description: "missing scope", scope: "read:library" }.to_json
    )

    error = assert_raises(HardcoverClient::ScopeError) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }
    assert_equal "read:library", error.scope
    assert_kind_of HardcoverClient::AuthenticationError, error
  end

  test "an oversized request is reported as non-retryable" do
    credential = HardcoverClient.credential_for_token("hc_at_burst")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(
      status: 403, headers: { "Content-Type" => "application/json" },
      body: { errors: [ "request_exceeds_capacity" ], message: "Too many top-level fields" }.to_json
    )

    assert_raises(HardcoverClient::QueryTooLargeError) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }
  end

  test "401 and a generic 403 are authentication failures" do
    credential = HardcoverClient.credential_for_token("hc_at_revoked")
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(status: 401, body: { error: "invalid_token" }.to_json, headers: { "Content-Type" => "application/json" })
      .then.to_return(status: 403, body: { error: "unsupported_operation" }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises(HardcoverClient::AuthenticationError) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }
    error = assert_raises(HardcoverClient::AuthenticationError) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }
    assert_not_kind_of HardcoverClient::ScopeError, error
  end

  test "service unavailability is a transient connection error" do
    credential = HardcoverClient.credential_for_token("hc_at_any")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 503, body: { error: "Service temporarily unavailable" }.to_json)

    assert_raises(HardcoverClient::TransientError) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }
  end

  test "GraphQL errors in a 200 response raise instead of returning empty data" do
    credential = HardcoverClient.credential_for_token("hc_at_any")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { errors: [ { message: "field 'lists' not found in type: 'query_root'" } ] }.to_json
    )

    error = assert_raises(HardcoverClient::Error) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }
    assert_includes error.message, "not found"
  end

  test "background requests stop before spending the reserved daily allowance" do
    credential = HardcoverClient.credential_for_token("hc_at_bg", budget_key: HardcoverClient.account_budget_key(11))
    low_daily = RATE_LIMIT_HEADERS.merge("RateLimit" => %("Free";r=9;t=0, "daily";r=40;t=3600))
    stub_hardcover_graphql({ "ShelfarrMe" => { "me" => [ { "id" => 11 } ] } }, headers: low_daily)

    HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential)
    error = assert_raises(HardcoverClient::RateLimitError) do
      HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential, background: true)
    end

    assert_operator error.retry_after, :>, 3000
    assert_equal 1, hardcover_requests.size, "the background request must not reach Hardcover"
    assert HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential), "interactive use keeps the reserve"
  end

  test "the instance token joins its owner's account budget once the account is known" do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_api_token, "instance_token")
    stub_hardcover_graphql("TestConnection" => { "me" => [ { "id" => 4242 } ] })

    assert HardcoverClient.test_connection

    instance = HardcoverClient.instance_credential
    personal = HardcoverClient.credential_for_token("hc_at_personal", budget_key: HardcoverClient.account_budget_key(4242))
    assert_equal personal.digest, instance.digest
    assert_equal "Bearer instance_token", instance.authorization_header
  end
end
