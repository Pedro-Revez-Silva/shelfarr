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

  # Hardcover's Free plan is a token bucket: a burst of 10 that refills at 60
  # a minute. Time is scaled down 22x so the test runs in about a second:
  # background pacing of 1.1s becomes 0.05s and the refill 1/22s.
  test "concurrent background jobs on one account are spaced inside the bucket's refill rate" do
    interval = 0.05
    refill_every = HardcoverClient::BACKGROUND_MIN_INTERVAL.fdiv(interval).then { |scale| 1.0 / scale }
    credential = HardcoverClient.credential_for_token("hc_at_shared", budget_key: HardcoverClient.account_budget_key(909))
    bucket = 10.0
    last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sends = []
    lock = Mutex.new
    stub_request(:post, HardcoverClient::BASE_URL).to_return do |_request|
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = remaining = nil
      lock.synchronize do
        bucket = [ 10.0, bucket + ((now - last) / refill_every) ].min
        last = now
        status = bucket >= 1 ? 200 : 429
        bucket -= 1 if status == 200
        remaining = bucket.floor
        sends << [ now, status, bucket ]
      end
      headers = {
        "Content-Type" => "application/json",
        "RateLimit-Policy" => %("Free";q=60;w=60;burst=10, "daily";q=5000;w=86400),
        "RateLimit" => %("Free";r=#{remaining};t=#{remaining.zero? ? 1 : 0}, "daily";r=4900;t=3600)
      }
      headers["Retry-After"] = "1" if status == 429
      { status: status, headers: headers, body: { data: { me: [ { id: 909 } ] } }.to_json }
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = HardcoverClient.stub(:background_min_interval, interval) do
      gate = Queue.new
      workers = 3.times.map do
        Thread.new do
          gate.pop
          8.times.count do
            HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential, background: true)
          end
        rescue HardcoverClient::Error => e
          e
        end
      end
      3.times { gate << true }
      Timeout.timeout(30) { workers.map(&:value) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal [ 8, 8, 8 ], results, "every job finishes all of its pages"
    assert_equal [ 200 ], sends.map { |send| send[1] }.uniq, "no request is rejected by the bucket"
    gaps = sends.map(&:first).each_cons(2).map { |earlier, later| later - earlier }
    # The gap is measured where the stub receives the request, so it carries a
    # few milliseconds of client overhead jitter.
    assert_operator gaps.min, :>=, interval * 0.7, "sends for one account are spaced out, not clustered"
    assert_operator sends.map(&:last).min, :>=, 7, "the burst allowance is never used up"
    assert_operator elapsed, :<, 24 * interval * 3, "pacing queues jobs fairly instead of starving them"
  end

  test "a background job waits out a short cooldown instead of failing" do
    credential = HardcoverClient.credential_for_token("hc_at_cool", budget_key: HardcoverClient.account_budget_key(910))
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(status: 200, headers: RATE_LIMIT_HEADERS.merge("RateLimit" => %("Free";r=0;t=1, "daily";r=4900;t=3600)), body: { data: { me: [ { id: 910 } ] } }.to_json)
      .then.to_return(status: 200, headers: RATE_LIMIT_HEADERS, body: { data: { me: [ { id: 910 } ] } }.to_json)

    HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential)
    assert_raises(HardcoverClient::RateLimitError) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential) }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential, background: true)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.5
    assert_requested :post, HardcoverClient::BASE_URL, times: 2
  end

  test "pacing recovers from a wall-clock jump instead of stalling the account" do
    credential = HardcoverClient.credential_for_token("hc_at_clock", budget_key: HardcoverClient.account_budget_key(911))
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 911 } ] })

    HardcoverClient.stub(:background_min_interval, 0.05) do
      travel_to(2.hours.from_now) { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential, background: true) }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      2.times { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential, background: true) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    end
    assert_equal 3, hardcover_requests.size
  end
end
