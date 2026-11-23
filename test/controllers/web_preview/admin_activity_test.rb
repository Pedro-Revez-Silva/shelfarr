# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AdminActivityTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  setup do
    ActivityLog.delete_all
    @member = users(:one)
    @admin = users(:two)
    @gone = User.create!(username: "gone_reader", name: "Gone Reader", password: "Password123!", role: :user)
    @gone.soft_delete!
  end

  def log(action, at:, user: nil, trackable: nil, details: {})
    ActivityLog.create!(action: action, user: user, trackable: trackable, details: details, ip_address: "203.0.113.77", controller: "SecretController", created_at: at)
  end

  def listing(user: @admin, **query)
    sign_in_as(user)
    with_preview_users(@member, @admin) do
      preview_get web_preview_api_admin_activity_path(query), user: user
    end
    response.parsed_body
  end

  def classic_rows(**query)
    with_env(WebPreview::Access::VARIABLE => nil) do
      get admin_activity_logs_path(query)
    end
    assert_response :success
    css_select("tbody tr").size
  end

  test "an administrator reads the newest entries with who did them, what they were about and only the details worth showing" do
    stored = Book.create!(title: "The Dispossessed", book_type: :ebook, file_path: "/library/dispossessed.epub")
    catalogue = Book.create!(title: "Not Yet Here", book_type: :ebook)
    request = Request.create!(book: stored, user: @member, status: :completed)
    token_log = log("user.api_token_created", at: 6.minutes.ago, user: @member, details: { api_token_id: 9, scopes: [ "search:read", "requests:write", "made:up", 4 ] })
    created = log("request.created", at: 5.minutes.ago, user: @member, trackable: request,
      details: { created_via: "api", external_source: "https://private.example/hook?token=s3cret", password: "hunter2" })
    edited = log("admin.user_updated", at: 4.minutes.ago, user: @admin, trackable: @gone, details: { changes: { role: "admin" } })
    removed = log("book.deleted", at: 3.minutes.ago, user: @admin, trackable: catalogue)
    shelved = log("upload.manually_matched", at: 2.minutes.ago, user: @admin, trackable: stored, details: { book_id: stored.id, choice: "existing" })
    system = log("request.completed", at: 1.minute.ago)

    body = listing

    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal @admin.id.to_s, body.fetch("account")
    assert_equal 100, body.fetch("limit")
    assert_equal false, body.fetch("more")
    member = { "id" => @member.id.to_s, "name" => "User One", "removed" => false }
    admin = { "id" => @admin.id.to_s, "name" => "Admin User", "removed" => false }
    assert_equal [
      { "id" => system.id.to_s, "at" => system.created_at.iso8601(3), "action" => "request.completed", "actor" => nil, "subject" => nil, "details" => {} },
      { "id" => shelved.id.to_s, "at" => shelved.created_at.iso8601(3), "action" => "upload.manually_matched", "actor" => admin,
        "subject" => { "kind" => "book", "id" => stored.id.to_s, "title" => "The Dispossessed", "in_library" => true }, "details" => { "match" => "existing" } },
      { "id" => removed.id.to_s, "at" => removed.created_at.iso8601(3), "action" => "book.deleted", "actor" => admin,
        "subject" => { "kind" => "book", "id" => catalogue.id.to_s, "title" => "Not Yet Here", "in_library" => false }, "details" => {} },
      { "id" => edited.id.to_s, "at" => edited.created_at.iso8601(3), "action" => "admin.user_updated", "actor" => admin,
        "subject" => { "kind" => "person", "id" => @gone.id.to_s, "name" => "Gone Reader", "removed" => true }, "details" => {} },
      { "id" => created.id.to_s, "at" => created.created_at.iso8601(3), "action" => "request.created", "actor" => member,
        "subject" => { "kind" => "request", "id" => request.id.to_s, "title" => "The Dispossessed" }, "details" => { "via" => "api" } },
      { "id" => token_log.id.to_s, "at" => token_log.created_at.iso8601(3), "action" => "user.api_token_created", "actor" => member,
        "subject" => nil, "details" => { "scopes" => [ "search:read", "requests:write" ] } }
    ], body.fetch("entries")
    [ "203.0.113.77", "SecretController", "private.example", "s3cret", "hunter2", "api_token_id", "book_id", "made:up" ].each do |hidden|
      assert_not_includes response.body, hidden
    end
  end

  test "the filter lists name everyone who can appear, removed people included, and every action on record" do
    log("user.login", at: 2.minutes.ago, user: @member)
    log("user.login", at: 1.minute.ago, user: @admin)
    log("request.failed", at: 1.minute.ago)

    body = listing

    assert_equal User.order(:name, :id).map { |user| { "id" => user.id.to_s, "name" => user.name, "removed" => user.deleted? } }, body.fetch("people")
    assert_includes body.fetch("people"), { "id" => @gone.id.to_s, "name" => "Gone Reader", "removed" => true }
    assert_equal [ "request.failed", "user.login" ], body.fetch("actions")
  end

  test "an entry whose subject is gone or has no title shows no subject, as the classic page does" do
    request = Request.create!(book: Book.create!(title: "Short Lived", book_type: :ebook), user: @member, status: :pending)
    orphan = log("request.cancelled", at: 2.minutes.ago, user: @admin, trackable: request)
    request.delete
    upload = Upload.create!(user: @member, original_filename: "private-name.epub", file_path: "/uploads/private-name.epub", status: :pending)
    untitled = log("upload.created", at: 1.minute.ago, user: @member, trackable: upload)

    entries = listing.fetch("entries").index_by { |entry| entry.fetch("id") }

    assert_nil entries.fetch(orphan.id.to_s).fetch("subject")
    assert_nil entries.fetch(untitled.id.to_s).fetch("subject")
    assert_not_includes response.body, "private-name"
  end

  test "the user, action and date filters match the classic page's results" do
    log("user.login", at: Time.utc(2026, 11, 20, 23, 59, 59), user: @member)
    log("user.login", at: Time.utc(2026, 11, 21, 0, 0, 0), user: @member)
    log("user.logout", at: Time.utc(2026, 11, 22, 8, 0, 0), user: @member)
    log("user.login", at: Time.utc(2026, 11, 22, 9, 0, 0), user: @admin)
    log("request.failed", at: Time.utc(2026, 11, 22, 10, 0, 0))

    [
      [ {}, 5 ],
      [ { user_id: @member.id.to_s }, 3 ],
      [ { action_filter: "user.login" }, 3 ],
      [ { from: "2026-11-21" }, 4 ],
      [ { user_id: @member.id.to_s, action_filter: "user.login", from: "2026-11-21" }, 1 ],
      [ { user_id: @gone.id.to_s }, 0 ],
      [ { action_filter: "never.happened" }, 0 ],
      [ { user_id: "", action_filter: "", from: "" }, 5 ]
    ].each do |query, count|
      warm = listing(**query).fetch("entries")
      assert_equal count, warm.size, query.inspect
      assert_equal count, classic_rows(**query), query.inspect
    end
    assert_equal [ Time.utc(2026, 11, 21).iso8601(3) ], listing(user_id: @member.id.to_s, action_filter: "user.login", from: "2026-11-21").fetch("entries").map { |entry| entry.fetch("at") }
  end

  test "a malformed filter is refused instead of being read as another filter" do
    log("request.completed", at: 1.minute.ago)
    [ { user_id: "abc" }, { user_id: "0" }, { from: "2026-02-30" }, { from: "21/11/2026" }, { action_filter: "x" * 201 }, { "user_id[]" => "1" } ].each do |query|
      body = listing(**query)
      assert_response :bad_request
      assert_equal({ "error" => "invalid_request" }, body, query.inspect)
    end
  end

  test "only the 100 most recent matching entries are sent, and the page is told there are more" do
    base = 2.days.ago
    rows = Array.new(101) { |index| { action: "user.login", user_id: @member.id, details: {}, created_at: base + index.minutes, updated_at: base } }
    ActivityLog.insert_all!(rows)

    body = listing
    assert_equal 100, body.fetch("entries").size
    assert_equal true, body.fetch("more")
    assert_equal ActivityLog.recent.limit(100).pluck(:id).map(&:to_s), body.fetch("entries").map { |entry| entry.fetch("id") }

    ActivityLog.recent.last.delete
    body = listing
    assert_equal 100, body.fetch("entries").size
    assert_equal false, body.fetch("more")
  end

  test "members, unlisted administrators, signed-out browsers and another account's page get no activity" do
    log("user.login", at: 1.minute.ago, user: @admin)

    listing(user: @member)
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)

    sign_in_as(@admin)
    with_preview_users(@member) do
      preview_get web_preview_api_admin_activity_path, user: @admin
      assert_response :not_found
      get web_preview_server_activity_path
      assert_response :not_found
    end
    with_env(WebPreview::Access::VARIABLE => nil) do
      preview_get web_preview_api_admin_activity_path, user: @admin
      assert_response :not_found
    end
    with_preview_users(@member, @admin) do
      preview_get web_preview_api_admin_activity_path, user: @member
      assert_response :unauthorized
      assert_equal({ "error" => "account_changed" }, response.parsed_body)
    end

    reset!
    with_preview_users(@admin) do
      preview_get web_preview_api_admin_activity_path, user: @admin
      assert_response :unauthorized
      assert_equal({ "error" => "signed_out" }, response.parsed_body)
      get web_preview_server_activity_path
      assert_redirected_to new_session_path
    end
    assert_not_includes response.body, "user.login"
  end

  test "the warm shell serves the activity address to listed accounts" do
    sign_in_as(@admin)
    with_preview_users(@admin) do
      get "/preview/server/system/activity?user=#{@member.id}&action=user.login"
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_select "script#shelfarr-boot"
    end
  end

  test "a classic bookmark sends a listed administrator to the warm page with the filters it can carry" do
    sign_in_as(@admin)
    with_preview_users(@admin) do
      get admin_activity_logs_path(user_id: @member.id, action_filter: "user.login", from: "2026-11-21")
      assert_redirected_to "http://www.example.com/preview/server/system/activity?action=user.login&from=2026-11-21&user=#{@member.id}"
      get admin_activity_logs_path
      assert_redirected_to "http://www.example.com/preview/server/system/activity"
      get admin_activity_logs_path(action_filter: "a&b=c d")
      assert_redirected_to "http://www.example.com/preview/server/system/activity?action=a%26b%3Dc+d"
      get admin_activity_logs_path(user_id: "abc", action_filter: "", from: "2026-02-30")
      assert_redirected_to "http://www.example.com/preview/server/system/activity"
      get admin_activity_logs_path(user_id: [ "1" ], action_filter: "request.created")
      assert_redirected_to "http://www.example.com/preview/server/system/activity?action=request.created"
    end
  end

  test "the classic page stays for unlisted administrators, with the preview off or unbuilt, and still turns members away" do
    log("user.login", at: 1.minute.ago, user: @admin)
    sign_in_as(@admin)
    with_preview_users(@member) do
      get admin_activity_logs_path
      assert_response :success
      assert_select "h1", "Activity Log"
    end
    with_env(WebPreview::Access::VARIABLE => nil) do
      get admin_activity_logs_path(action_filter: "user.login")
      assert_response :success
      assert_select "tbody tr", 1
    end
    with_preview_users(@admin) do
      WarmEntry.stub(:stylesheet_built?, false) do
        get admin_activity_logs_path
        assert_response :success
      end
    end

    sign_in_as(@member)
    with_preview_users(@member) do
      get admin_activity_logs_path
      assert_redirected_to root_path
    end
  end
end
