# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_account_test_helper"

class Kobo::AccountClientTest < ActiveSupport::TestCase
  include KoboAccountTestHelper

  setup do
    @account = create_kobo_account
    @client = Kobo::AccountClient.new(@account)
  end

  test "activation extracts only code and validated workflow without forwarding a Shelfarr session" do
    stub_kobo_activation
    result = @client.start_activation
    assert_equal POLL_PATH, result.poll_url
    assert_equal "123456", result.code
    assert_in_delta 10.minutes.from_now.to_i, result.expires_at.to_i, 1
    assert_requested :get, %r{\A#{Regexp.escape(AUTH)}/ActivateOnWeb\?} do |request|
      request.headers["Authorization"].nil? && request.headers["Cookie"].nil?
    end
  end

  test "activation accepts Kobo's own absolute poll URL but rejects all other destinations" do
    stub_kobo_activation(poll: AUTH + POLL_PATH)
    assert_equal POLL_PATH, @client.start_activation.poll_url
    [ "https://evil.example#{POLL_PATH}", "//evil.example#{POLL_PATH}", "http://auth.kobobooks.com#{POLL_PATH}",
      "https://auth.kobobooks.com:444#{POLL_PATH}", "https://user:password@auth.kobobooks.com#{POLL_PATH}",
      "/../activateonweb/poll?workflowId=abc", "/v1/user?workflowId=abc", POLL_PATH + "&workflowId=duplicate", POLL_PATH + "&url=https://evil.example" ].each do |url|
      stub_kobo_activation(poll: url)
      assert_equal "protocol_changed", assert_raises(Kobo::HttpClient::Error) { @client.start_activation }.code
    end
  end

  test "malformed activation HTML fails without rendering its contents" do
    stub_request(:get, %r{\A#{Regexp.escape(AUTH)}/ActivateOnWeb\?}).to_return(body: "<script>provider-error</script>")
    assert_raises(Kobo::HttpClient::Error) { @client.start_activation }
  end

  test "pending returns no identity while completed approval parses credentials without fetching the redirect" do
    stub_kobo_approval(status: "Pending")
    assert_nil @client.poll_activation
    stub_kobo_approval
    identity = @client.poll_activation
    assert_equal "synthetic-user-id", identity.user_id
    assert_equal "synthetic-user-key", identity.user_key
    assert_equal "reader@example.test", identity.email
    stub_kobo_tokens
    credentials = @client.authenticate(identity)
    assert_equal "synthetic-access", credentials.fetch(:access_token)
    assert_equal identity.user_id, credentials.fetch(:kobo_user_id)
    assert_equal identity.email, credentials.fetch(:kobo_email)
    assert_not_requested(:get, /UserAuthenticated/)
  end

  test "expired unknown duplicated missing and arbitrary redirect credentials fail closed" do
    stub_kobo_approval(status: "Expired")
    assert_equal "activation_expired", assert_raises(Kobo::HttpClient::Error) { @client.poll_activation }.code
    stub_kobo_approval(status: "SomethingElse")
    assert_raises(Kobo::HttpClient::Error) { @client.poll_activation }
    [ "https://evil.example/?userId=abc&userKey=def&email=a", "kobo://UserAuthenticated?userId=abc&email=a",
      "kobo://UserAuthenticated?userId=abc&userKey=def&email=a&userKey=duplicate",
      "kobo://UserAuthenticated/other?userId=abc&userKey=def&email=a",
      "kobo://UserAuthenticated?userId=abc&userKey=def%0D%0Aevil&email=a" ].each do |redirect|
      stub_kobo_approval(redirect: redirect)
      assert_raises(Kobo::HttpClient::Error) { @client.poll_activation }
    end
  end

  test "device and refresh credentials require real bearer token fields" do
    identity = Kobo::AccountClient::Identity.new(user_id: "id", user_key: "key", email: "reader@example.test")
    [ {}, { TokenType: "Basic", AccessToken: "a", RefreshToken: "b" },
      { TokenType: "Bearer", AccessToken: "a" }, { TokenType: "Bearer", AccessToken: "a\r\nb", RefreshToken: "c" } ].each do |tokens|
      stub_request(:post, STORE + "/v1/auth/device").to_return(body: tokens.to_json)
      assert_raises(Kobo::HttpClient::Error) { @client.authenticate(identity) }
    end
    @account.update!(access_token: "old-access", refresh_token: "old-refresh")
    stub_request(:post, STORE + "/v1/auth/refresh").with(headers: { "Authorization" => "Bearer old-access" },
      body: hash_including("RefreshToken" => "old-refresh")).to_return(body: kobo_tokens(access: "new-access"))
    assert_equal "new-access", @client.refresh.fetch(:access_token)
  end

  test "catalogue continuation requires an opaque bounded token and a JSON array" do
    @account.update!(access_token: "synthetic-access")
    stub_request(:get, STORE + "/v1/library/sync").to_return(body: [ kobo_book ].to_json,
      headers: { "x-kobo-sync" => "continue", "x-kobo-synctoken" => "store-page-2" })
    page = @client.library_page
    assert page.more
    assert_equal "store-page-2", page.cursor
    assert_equal 1, page.items.size
    [ "{}", "not-json", "[1]" ].each do |body|
      stub_request(:get, STORE + "/v1/library/sync").to_return(body: body)
      assert_raises(Kobo::HttpClient::Error) { @client.library_page }
    end
    stub_request(:get, STORE + "/v1/library/sync").to_return(body: "[]", headers: { "x-kobo-sync" => "continue" })
    assert_raises(Kobo::HttpClient::Error) { @client.library_page }
  end
end
