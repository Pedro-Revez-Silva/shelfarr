# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::RequestsTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  setup do
    prepare_consumer_library
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    @member = User.create!(username: "tracker_member", name: "User One", password: "Password123!", role: :user)
    @admin = User.create!(username: "tracker_admin", name: "Admin User", password: "Password123!", role: :admin)
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
    @mine = Request.create!(book: Book.create!(title: "Émile and the Lighthouse", author: "Ana Writer", book_type: :ebook, open_library_work_id: "OL700W"), user: @member, status: :searching, notes: "Second edition please")
    @theirs = Request.create!(book: Book.create!(title: "Someone Else's Book", book_type: :audiobook), user: @admin, status: :not_found, attention_needed: true, issue_description: "No copies after 3 searches")
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def list(user:, **params)
    preview_get web_preview_api_requests_path(**params), user: user
    assert_response :success
    response.parsed_body
  end

  def detail(request, user:)
    preview_get web_preview_api_request_path(request), user: user
    response.parsed_body
  end

  def post_action(path, user:, **body)
    post path, params: body, headers: account_headers(user), as: :json
    response.parsed_body
  end

  test "a member lists only their own requests, without requesters, with the same filters and counts as the classic page" do
    sign_in_as(@member)
    body = list(user: @member)
    assert_equal @member.id.to_s, body.fetch("account")
    assert_equal "own", body.fetch("scope")
    assert_equal [ @mine.id.to_s ], body.fetch("items").map { |item| item.fetch("id") }
    item = body.fetch("items").sole
    assert_not item.key?("requested_by")
    assert_equal({ "source" => "openlibrary", "id" => "OL700W" }, item.fetch("book_page"))
    assert_equal({ "attention" => 0, "active" => 1 }, body.fetch("counts"))
    assert_equal({ "status" => nil, "attention" => false, "q" => nil }, body.fetch("filter"))
    assert_equal [ 1, 25, 1, 1 ], body.values_at("page", "per_page", "total", "total_pages")
    assert_equal [], list(user: @member, status: "not_found").fetch("items")
  end

  test "an administrator lists every request with its requester, and searching folds Unicode case like the classic page" do
    sign_in_as(@admin)
    body = list(user: @admin)
    assert_equal "all", body.fetch("scope")
    ids = body.fetch("items").map { |item| item.fetch("id") }
    assert_equal [ @theirs.id.to_s, @mine.id.to_s ], ids.first(2)
    assert_equal Request.count, body.fetch("total")
    assert_equal({ "name" => "User One", "self" => false }, body.fetch("items").second.fetch("requested_by"))
    assert_equal({ "attention" => Request.needs_attention.count, "active" => Request.active.where(attention_needed: false).count }, body.fetch("counts"))
    assert_includes list(user: @admin, attention: "true").fetch("items").map { |item| item.fetch("id") }, @theirs.id.to_s
    assert_not_includes list(user: @admin, attention: "true").fetch("items").map { |item| item.fetch("id") }, @mine.id.to_s
    assert_equal [ @mine.id.to_s ], list(user: @admin, q: "  ÉMILE ").fetch("items").map { |item| item.fetch("id") }
    assert_equal "ÉMILE", list(user: @admin, q: "  ÉMILE ").dig("filter", "q")
    preview_get web_preview_api_requests_path(status: "everything"), user: @admin
    assert_response :bad_request
  end

  test "a member sees their own request's details and actions but not another account's request, copies or diagnostics" do
    @mine.search_results.create!(guid: "copy", title: "Émile.epub", source: SearchResult::SOURCE_GUTENBERG, download_url: "https://files.example.test/e.epub")
    @mine.update!(attention_needed: true, issue_description: "Émile.epub from Gutenberg needs a choice")
    RequestEvent.record!(request: @mine, event_type: "dispatch_failed", source: "test", message: "Client down", level: :error)
    sign_in_as(@member)
    request = detail(@mine, user: @member).fetch("request")
    assert_nil request.fetch("attention_reason")
    assert request.fetch("choice_needed")
    assert_not_includes response.body, "Émile.epub"
    assert_equal "Second edition please", request.fetch("notes")
    assert_equal({ "cancel" => true, "remove" => nil, "retry" => false, "search_again" => false, "manual_download" => false,
      "replaces_library_file" => false, "upload_url" => nil, "download_url" => nil }, request.fetch("actions"))
    assert_not request.key?("copies")
    assert_not request.key?("events")
    detail(@theirs, user: @member)
    assert_response :not_found
  end

  test "an administrator sees copies, diagnostics, the attention reason and every admin action" do
    @theirs.search_results.create!(guid: "copy", title: "Audio.m4b", source: SearchResult::SOURCE_GUTENBERG, download_url: "https://files.example.test/a.m4b")
    RequestEvent.record!(request: @theirs, event_type: "dispatch_failed", source: "test", message: "Client down", level: :error)
    sign_in_as(@admin)
    request = detail(@theirs, user: @admin).fetch("request")
    assert_equal "No copies after 3 searches", request.fetch("attention_reason")
    assert_equal({ "name" => "Admin User", "self" => true }, request.fetch("requested_by"))
    assert_equal %w[admin_remove], [ request.dig("actions", "remove") ]
    assert request.dig("actions", "retry")
    assert request.dig("actions", "search_again")
    assert request.dig("actions", "manual_download")
    assert_equal "/admin/uploads/new?request_id=#{@theirs.id}", request.dig("actions", "upload_url")
    assert_equal [ "Audio.m4b" ], request.dig("copies", "candidates").map { |copy| copy.fetch("title") }
    assert request.dig("copies", "selectable")
    assert_equal [ { "title" => "Dispatch Failed", "message" => "Client down", "level" => "error" } ], request.fetch("events").map { |event| event.except("at") }
  end

  test "a completed request links to the library copy the browser opens and offers its download and history removal to its owner" do
    @mine.update!(book: @ebook, status: :completed, completed_at: Time.current)
    sign_in_as(@member)
    request = detail(@mine, user: @member).fetch("request")
    assert_equal({ "state" => "available", "publication_id" => @ebook.id.to_s }, request.fetch("library"))
    assert_equal "delete_history", request.dig("actions", "remove")
    assert_not request.dig("actions", "cancel")
    assert_equal "/requests/#{@mine.id}/download", request.dig("actions", "download_url")
    assert_equal({ "status" => "removed", "id" => @mine.id.to_s }, post_action(web_preview_api_request_remove_path(@mine), user: @member).fetch("request"))
    assert_not Request.exists?(@mine.id)
    assert Book.exists?(@ebook.id)
  end

  test "a member cannot delete an unfinished request, retry, add a link or act on another account's request" do
    sign_in_as(@member)
    assert_equal "cannot_remove", post_action(web_preview_api_request_remove_path(@mine), user: @member).fetch("error")
    assert_response :conflict
    post_action(web_preview_api_request_remove_path(@theirs), user: @member)
    assert_response :not_found
    post_action(web_preview_api_request_retry_path(@mine), user: @member)
    assert_response :not_found
    post_action(web_preview_api_request_manual_path(@mine), user: @member, kind: "magnet", url: "magnet:?xt=urn:btih:#{"a" * 40}")
    assert_response :not_found
    assert Request.exists?(@mine.id)
  end

  test "an administrator retries a request, removes another account's request and keeps the book of a completed one" do
    sign_in_as(@admin)
    body = post_action(web_preview_api_request_retry_path(@theirs), user: @admin)
    assert_response :success
    assert_equal @theirs.id.to_s, body.dig("request", "id")
    assert_equal "pending", @theirs.reload.status
    post_action(web_preview_api_request_remove_path(@mine), user: @admin)
    assert_response :success
    assert_not Request.exists?(@mine.id)
    @theirs.update!(book: @ebook, status: :completed, completed_at: Time.current)
    post_action(web_preview_api_request_remove_path(@theirs), user: @admin)
    assert_response :success
    assert Book.exists?(@ebook.id)
  end

  test "an administrator adds a manual link, and a bad link is refused with the model's reason" do
    sign_in_as(@admin)
    assert_equal "Enter a valid magnet link", post_action(web_preview_api_request_manual_path(@mine), user: @admin, kind: "magnet", url: "http://nope").fetch("message")
    assert_response :unprocessable_entity
    post_action(web_preview_api_request_manual_path(@mine), user: @admin, kind: "torrent", url: "x")
    assert_response :unprocessable_entity
  end

  test "request actions need the page's CSRF token and every read needs the account header" do
    sign_in_as(@member)
    get web_preview_api_requests_path, headers: { "Accept" => "application/json" }
    assert_response :unauthorized
    with_forgery_protection do
      post_action(web_preview_api_request_remove_path(@mine), user: @member)
      assert_response :unprocessable_entity
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
    end
  end

  test "the request tracker addresses load the preview shell" do
    sign_in_as(@member)
    get "/preview/requests"
    assert_response :success
    assert_select "#shelfarr-boot"
    get "/preview/requests/#{@mine.id}"
    assert_response :success
    get "/preview/account"
    assert_response :success
  end
end
