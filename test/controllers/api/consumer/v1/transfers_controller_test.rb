# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/consumer_test_helper"

class API::Consumer::V1::TransfersControllerTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  setup do
    prepare_consumer_library
    @asset = consumer_asset(@audiobook)
    @original = File.binread(@audio_path)
  end
  teardown { FileUtils.remove_entry(@root) }

  test "a bearer mints a private grant URL under the deployment for one asset generation" do
    freeze_time do
      post grant_endpoint, headers: @headers, as: :json, params: {}
      assert_response :created
      assert_private
      body = response.parsed_body
      assert_equal %w[expires_at url], body.keys.sort
      assert_match %r{\A/api/consumer/v1/library/#{@audiobook.id}/assets/#{@asset.id}/transfer\?grant=[A-Za-z0-9_-]+\z}, body.fetch("url")
      assert_equal 24.hours.from_now.utc.iso8601, body.fetch("expires_at")
      assert_not_includes body.fetch("url"), @headers.fetch("Authorization").delete_prefix("Bearer ")
      assert_nil response.headers["Location"]
    end

    post grant_endpoint, headers: @headers, env: { "SCRIPT_NAME" => "/books" }
    assert_response :created
    url = response.parsed_body.fetch("url")
    assert url.start_with?("/books/api/consumer/v1/library/#{@audiobook.id}/assets/#{@asset.id}/transfer?grant="), url
    get url.delete_prefix("/books"), env: { "SCRIPT_NAME" => "/books" }
    assert_response :success
    assert_equal @original, response.body
  end

  test "grants never outlive the issuing token" do
    @token.update!(expires_at: 2.hours.from_now)
    url = grant_url
    assert_equal @token.expires_at.utc.iso8601, response.parsed_body.fetch("expires_at")
    travel 2.hours + 1.second do
      get url
      assert_invalid_grant
    end
  end

  test "grant requests need the bearer with library read and a current asset" do
    post grant_endpoint
    assert_response :unauthorized
    _, raw = APIToken.issue!(name: "Progress only", user: users(:one), scopes: [ "progress:write" ])
    post grant_endpoint, headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body.fetch("error")
    post "/api/consumer/v1/library/#{@audiobook.id}/assets/#{"0" * 64}/transfer_grant", headers: @headers
    assert_response :gone
    post "/api/consumer/v1/library/#{@audiobook.id}/assets/not-an-asset/transfer_grant", headers: @headers
    assert_response :gone
    post "/api/consumer/v1/library/#{@audiobook.id}x/assets/#{@asset.id}/transfer_grant", headers: @headers
    assert_response :not_found
    get grant_endpoint, headers: @headers
    assert_response :not_found
    post grant_endpoint, headers: @headers.merge("Content-Type" => "application/json"), params: "x" * (65 * 1024)
    assert_response :content_too_large
  end

  test "grant bytes keep the bearer endpoint's validators ranges and conditional semantics" do
    url = grant_url
    get url
    assert_response :success
    assert_private
    assert_equal @original, response.body
    assert_equal "audio/mpeg", response.media_type
    etag = response.headers.fetch("ETag")
    assert_equal %Q("#{@asset.id}"), etag
    get url, headers: { "If-None-Match" => etag }
    assert_response :not_modified
    assert_private
    head url, headers: { "Range" => "bytes=0-4" }
    assert_response :ok
    assert_equal @original.size.to_s, response.headers["Content-Length"]
    assert_equal "", response.body
    { "bytes=0-4" => @original.byteslice(0, 5), "bytes=7-" => @original.byteslice(7..), "bytes=-5" => @original.byteslice(-5, 5) }.each do |range, bytes|
      get url, headers: { "Range" => range, "If-Range" => etag }
      assert_response :partial_content
      assert_equal bytes, response.body
      assert_private
    end
    get url, headers: { "Range" => "bytes=0-4", "If-Range" => '"old-edition"' }
    assert_response :ok
    assert_equal @original, response.body
    %w[bytes=900- bytes=0-1,4-5].each do |range|
      get url, headers: { "Range" => range }
      assert_response :range_not_satisfiable
      assert_equal "bytes */#{@original.size}", response.headers["Content-Range"]
    end
    assert_nil response.headers["Location"]
  end

  test "replacing or removing the asset invalidates its grant with gone or not found" do
    url = grant_url
    File.rename(@audio_path, "#{@audio_path}.old")
    File.write(@audio_path, "a different media edition")
    get url
    assert_response :gone
    assert_private
    assert_not_includes response.body, @root
    @audiobook.update!(file_path: nil)
    get url
    assert_response :not_found
    assert_private
  end

  test "grants follow the live token user and scope" do
    url = grant_url
    get url
    assert_response :success
    @token.update!(scopes: [ "progress:write" ].to_json)
    get url
    assert_invalid_grant
    @token.update!(scopes: ConsumerDeviceGrant::SCOPES.to_json, expires_at: 1.second.ago)
    get url
    assert_invalid_grant
    @token.update!(expires_at: nil)
    users(:one).update!(deleted_at: Time.current)
    get url
    assert_invalid_grant
    users(:one).update!(deleted_at: nil)
    get url
    assert_response :success
    post "/api/consumer/v1/auth/revoke", headers: @headers
    get url
    assert_invalid_grant
    @token.destroy!
    get url
    assert_invalid_grant
  end

  test "grants expire after a day" do
    url = grant_url
    travel 24.hours - 1.minute do
      get url
      assert_response :success
    end
    travel 24.hours + 1.second do
      get url
      assert_invalid_grant
    end
  end

  test "a grant opens only its own publication and asset and only with GET or HEAD" do
    url = grant_url
    grant = url[/grant=(.+)\z/, 1]
    ebook_asset = consumer_asset(@ebook)
    get "/api/consumer/v1/library/#{@ebook.id}/assets/#{ebook_asset.id}/transfer?grant=#{grant}"
    assert_invalid_grant
    get "/api/consumer/v1/library/#{@ebook.id}/assets/#{@asset.id}/transfer?grant=#{grant}"
    assert_invalid_grant
    get "/api/consumer/v1/library/#{@audiobook.id}/assets/#{ebook_asset.id}/transfer?grant=#{grant}"
    assert_invalid_grant
    tampered = grant.dup
    tampered[20] = tampered[20] == "A" ? "B" : "A"
    get url.sub(grant, tampered)
    assert_invalid_grant

    %i[post put patch delete].each do |verb|
      process verb, url
      assert_response :not_found, verb
    end
    get "/api/consumer/v1/library/#{@audiobook.id}/assets/#{@asset.id}?grant=#{grant}"
    assert_response :unauthorized
    get "/api/consumer/v1/library/#{@audiobook.id}?grant=#{grant}"
    assert_response :unauthorized
    get "/api/consumer/v1/library?grant=#{grant}"
    assert_response :unauthorized
    get "/api/consumer/v1/library/#{@audiobook.id}/progress?grant=#{grant}"
    assert_response :unauthorized
    put "/api/consumer/v1/library/#{@audiobook.id}/progress?grant=#{grant}", params: audio_progress, as: :json
    assert_response :unauthorized
    get "/api/consumer/v1/library", headers: { "Authorization" => "Bearer #{grant}" }
    assert_response :unauthorized
  end

  test "only a literal grant query parameter authorizes bytes and nothing else does" do
    url = grant_url
    grant = url[/grant=(.+)\z/, 1]
    path = url.split("?").first
    get path, headers: @headers
    assert_invalid_grant
    SettingsService.set(:api_token, "legacy-global-token")
    get "#{path}?grant=legacy-global-token"
    assert_invalid_grant
    get "#{path}?grant=#{@headers.fetch("Authorization").delete_prefix("Bearer ")}"
    assert_invalid_grant
    _, other = APIToken.issue!(name: "Another reader", user: users(:two), scopes: ConsumerDeviceGrant::SCOPES)
    get "#{path}?grant=#{other}"
    assert_invalid_grant
    sign_in_as(users(:one))
    get path
    assert_invalid_grant
    [ "gr%61nt=#{grant}", "GRANT=#{grant}", "grant[]=#{grant}", "grant=#{grant}&grant=#{grant}", "grant=#{grant}&x=1", "grant=#{grant};x=1" ].each do |query|
      get "#{path}?#{query}"
      assert_invalid_grant
    end
    get url, headers: { "Authorization" => "Bearer not-a-token" }
    assert_response :success
  end

  test "grant values stay out of request logs including unknown routes and encoded keys" do
    url = grant_url
    grant = url[/grant=(.+)\z/, 1]
    log = capture_log do
      get url
      head url
      get url.sub("/transfer?", "/elsewhere?")
      get "/api/consumer/v1/nowhere?grant=#{grant}"
      get "/nowhere?gr%61nt=#{grant}&x[grant]=#{grant}&grant[]=#{grant}&Grant=#{grant};grant=#{grant}"
    end
    # Short messages: a failure must not print the captured log and its grants.
    assert log.include?("/api/consumer/v1/nowhere?grant=[FILTERED]"), "unknown route query is filtered"
    assert log.include?("gr%61nt=[FILTERED]&x[grant]=[FILTERED]&grant[]=[FILTERED]"), "encoded and nested keys are filtered"
    assert_not log.include?(grant), "no grant value is logged"
    assert_operator log.scan("[FILTERED]").size, :>=, 9
  end

  private

  def grant_endpoint
    "/api/consumer/v1/library/#{@audiobook.id}/assets/#{@asset.id}/transfer_grant"
  end

  def grant_url
    post grant_endpoint, headers: @headers, as: :json, params: {}
    assert_response :created
    response.parsed_body.fetch("url")
  end

  def assert_private
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  def assert_invalid_grant
    assert_response :unauthorized
    assert_equal({ "error" => "invalid_grant" }, response.parsed_body)
    assert_private
  end

  def capture_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end
end
