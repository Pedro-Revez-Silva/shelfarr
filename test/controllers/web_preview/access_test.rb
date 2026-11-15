# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AccessControllerTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper

  setup { prepare_consumer_library }
  teardown { FileUtils.remove_entry(@root) }

  def api_paths
    [ web_preview_api_session_path, web_preview_api_library_path, web_preview_api_continue_path, "#{web_preview_api_library_path}/#{@ebook.id}" ]
  end

  def shell_paths
    [ web_preview_path, web_preview_library_path, web_preview_publication_path(@ebook) ]
  end

  test "with no configuration every shell and API route is not found, even signed out" do
    [ nil, "", "nope" ].each do |raw|
      with_env(WebPreview::Access::VARIABLE => raw) do
        shell_paths.each do |path|
          get path
          assert_response :not_found, path
        end
        api_paths.each do |path|
          get path, headers: account_headers(users(:one))
          assert_response :not_found, path
          assert_equal({ "error" => "not_found" }, response.parsed_body)
        end
        sign_in_as(users(:one))
        shell_paths.each { |path| get path; assert_response :not_found, path }
        api_paths.each { |path| get path, headers: account_headers(users(:one)); assert_response :not_found, path }
        put "#{web_preview_api_library_path}/#{@ebook.id}/reading_status", params: { status: "finished" }, headers: account_headers(users(:one)), as: :json
        assert_response :not_found
        assert_equal 0, ConsumerReadingState.count
        sign_out
      end
    end
  end

  test "a signed-out browser is sent to sign in for the shell and refused JSON without data" do
    with_preview_users(users(:one)) do
      get web_preview_library_path
      assert_redirected_to new_session_path
      api_paths.each do |path|
        get path, headers: account_headers(users(:one))
        assert_response :unauthorized, path
        assert_equal({ "error" => "signed_out" }, response.parsed_body)
        assert_not_includes response.body, @ebook.title
      end
      put "#{web_preview_api_library_path}/#{@ebook.id}/reading_status", params: { status: "finished" }, as: :json
      assert_response :unauthorized
      assert_equal 0, ConsumerReadingState.count
    end
  end

  test "a signed-in user who is not enabled cannot fetch the shell or API by guessing URLs" do
    with_preview_users(users(:two)) do
      sign_in_as(users(:one))
      shell_paths.each do |path|
        get path
        assert_response :not_found, path
        assert_not_includes response.body, "shelfarr-boot"
      end
      api_paths.each do |path|
        get path, headers: account_headers(users(:one))
        assert_response :not_found, path
        assert_equal({ "error" => "not_found" }, response.parsed_body)
      end
      put "#{web_preview_api_library_path}/#{@ebook.id}/reading_status", params: { status: "finished" }, headers: account_headers(users(:one)), as: :json
      assert_response :not_found
      assert_equal 0, ConsumerReadingState.count
    end
  end

  test "an enabled user gets the shell with a strict policy and nothing personal beyond the account binding" do
    with_forgery_protection do
    with_preview_users(users(:one)) do
      sign_in_as(users(:one))
      get web_preview_path
      assert_redirected_to web_preview_library_path
      get web_preview_library_path
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
      policy = response.headers["Content-Security-Policy"]
      assert_includes policy, "script-src 'self'"
      assert_includes policy, "style-src 'self'"
      assert_no_match(/unsafe-inline|unsafe-eval/, policy)
      assert_select "script:not([type='application/json']):not([src])", count: 0
      assert_select "[style]", count: 0
      boot = JSON.parse(css_select("script#shelfarr-boot").sole.text)
      assert_equal({ "version" => 1, "account" => users(:one).id.to_s, "mount" => "/preview", "api" => "/preview/api/v1", "classic_library" => "/read" }, boot)
      assert_select "meta[name=csrf-token]"
      assert_select "script[type=module][src*='web/preview']"
      assert_select "link[rel=stylesheet][href*='web/preview']"
      assert_not_includes response.body, @ebook.title
      get web_preview_publication_path(@ebook)
      assert_response :success
      get "/preview/library/abc"
      assert_response :not_found
    end
    end
  end

  test "an API request must name the account it was built for" do
    with_preview_users(users(:one), users(:two)) do
      sign_in_as(users(:one))
      [ {}, { "X-Shelfarr-Account" => users(:two).id.to_s }, { "X-Shelfarr-Account" => "" }, { "X-Shelfarr-Account" => "#{users(:one).id} " } ].each do |headers|
        api_paths.each do |path|
          get path, headers: headers
          assert_response :unauthorized, "#{path} #{headers}"
          assert_equal({ "error" => "account_changed" }, response.parsed_body)
        end
        put "#{web_preview_api_library_path}/#{@ebook.id}/reading_status", params: { status: "finished" }, headers: headers, as: :json
        assert_response :unauthorized
      end
      assert_equal 0, ConsumerReadingState.count
    end
  end

  test "a tab built for one account cannot read or change anything after another tab signs in as someone else" do
    with_preview_users(users(:one), users(:two)) do
      sign_in_as(users(:one))
      preview_get web_preview_api_library_path
      assert_response :success
      assert_equal users(:one).id.to_s, response.parsed_body.fetch("account")
      sign_out
      sign_in_as(users(:two))
      preview_get web_preview_api_library_path, user: users(:one)
      assert_response :unauthorized
      assert_equal "account_changed", response.parsed_body.fetch("error")
      assert_not_includes response.body, @ebook.title
      with_forgery_protection do
        token = csrf_token
        put "#{web_preview_api_library_path}/#{@ebook.id}/reading_status", params: { status: "finished" }, headers: account_headers(users(:one)).merge("X-CSRF-Token" => token), as: :json
      end
      assert_response :unauthorized
      assert_equal 0, ConsumerReadingState.count
      preview_get web_preview_api_library_path, user: users(:two)
      assert_response :success
      assert_equal users(:two).id.to_s, response.parsed_body.fetch("account")
    end
  end

  test "responses are private and never cached" do
    with_preview_users(users(:one)) do
      sign_in_as(users(:one))
      api_paths.each do |path|
        preview_get path
        assert_response :success, path
        assert_equal "private, no-store", response.headers["Cache-Control"], path
        assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      end
    end
  end
end
