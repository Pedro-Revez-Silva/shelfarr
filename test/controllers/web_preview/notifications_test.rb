# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::NotificationsTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  setup do
    @member = users(:one)
    @admin = users(:two)
    @other = User.create!(username: "inbox_other", name: "Other Reader", password: "Password123!", role: :user)
    @book = Book.create!(title: "The Lighthouse Inbox", book_type: :ebook)
    @mine = Request.create!(book: @book, user: @member, status: :completed)
    @theirs = Request.create!(book: Book.create!(title: "Their Inbox Book", book_type: :audiobook), user: @other, status: :failed)
  end

  def notify(user, at:, type: "request_completed", title: "Book Ready", message: "Ready to read.", notifiable: nil, read: false)
    user.notifications.create!(notification_type: type, title: title, message: message, notifiable: notifiable, created_at: at, read_at: read ? at : nil)
  end

  def listing(user)
    preview_get web_preview_api_notifications_path, user: user
    assert_response :success
    response.parsed_body
  end

  def command(path, user:, **body)
    post path, params: body, headers: account_headers(user), as: :json
    response.parsed_body
  end

  test "a member lists only their own notifications, newest first, with every alert type, links to their requests and honest counts" do
    attention = notify(@member, at: 1.hour.ago, type: "request_attention", title: "Attention Needed", message: "\"The Lighthouse Inbox\" needs your attention.", notifiable: @mine)
    failed = notify(@member, at: 2.hours.ago, type: "request_failed", title: "Request Failed", message: nil, notifiable: @mine, read: true)
    ready = notify(@member, at: 10.minutes.ago, notifiable: @mine)
    notify(@other, at: 5.minutes.ago, title: "Someone else's alert", notifiable: @theirs)

    with_preview_users(@member, @other) do
      sign_in_as(@member)
      body = listing(@member)
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_equal({ "account" => @member.id.to_s, "unread" => 2, "total" => 3 }, body.except("items"))
      assert_equal [
        { "id" => ready.id.to_s, "type" => "request_completed", "title" => "Book Ready", "message" => "Ready to read.", "created_at" => ready.created_at.iso8601(3), "read_at" => nil,
          "request" => { "state" => "available", "id" => @mine.id.to_s } },
        { "id" => attention.id.to_s, "type" => "request_attention", "title" => "Attention Needed", "message" => "\"The Lighthouse Inbox\" needs your attention.", "created_at" => attention.created_at.iso8601(3), "read_at" => nil,
          "request" => { "state" => "available", "id" => @mine.id.to_s } },
        { "id" => failed.id.to_s, "type" => "request_failed", "title" => "Request Failed", "message" => nil, "created_at" => failed.created_at.iso8601(3), "read_at" => failed.read_at.iso8601(3),
          "request" => { "state" => "available", "id" => @mine.id.to_s } }
      ], body.fetch("items")
      assert_not_includes response.body, "Someone else"
      assert_not_includes response.body, @theirs.id.to_s
    end
  end

  test "the list shows the twenty most recent while the counts cover every notification" do
    oldest = notify(@member, at: 3.days.ago, title: "Oldest")
    21.times { |index| notify(@member, at: (30 - index).minutes.ago, title: "Alert #{index}", read: index.even?) }
    with_preview_users(@member) do
      sign_in_as(@member)
      body = listing(@member)
      assert_equal 20, body.fetch("items").size
      assert_equal [ 22, 11 ], body.values_at("total", "unread")
      assert_equal "Alert 20", body.fetch("items").first.fetch("title")
      assert_not_includes body.fetch("items").map { |item| item.fetch("id") }, oldest.id.to_s
    end
  end

  test "a removed request, another account's request and a notification without a subject are reported honestly without leaking" do
    removed = Request.create!(book: Book.create!(title: "Removed Book", book_type: :ebook), user: @member, status: :completed)
    gone = notify(@member, at: 3.minutes.ago, notifiable: removed)
    removed.delete
    foreign = notify(@member, at: 2.minutes.ago, notifiable: @theirs)
    plain = notify(@member, at: 1.minute.ago, notifiable: nil)
    with_preview_users(@member, @admin) do
      sign_in_as(@member)
      targets = listing(@member).fetch("items").to_h { |item| [ item.fetch("id"), item.fetch("request") ] }
      assert_equal({ plain.id.to_s => nil, foreign.id.to_s => { "state" => "unavailable" }, gone.id.to_s => { "state" => "unavailable" } }, targets)
      assert_not_includes response.body, @theirs.id.to_s

      sign_in_as(@admin)
      seen = notify(@admin, at: 1.minute.ago, type: "request_attention", notifiable: @theirs)
      body = listing(@admin)
      assert_equal [ seen.id.to_s ], body.fetch("items").map { |item| item.fetch("id") }
      assert_equal({ "state" => "available", "id" => @theirs.id.to_s }, body.fetch("items").sole.fetch("request"))
      assert_equal [ 1, 1 ], body.values_at("unread", "total")
    end
  end

  test "an administrator's inbox holds only their own notifications" do
    notify(@member, at: 1.minute.ago, title: "Member alert")
    own = notify(@admin, at: 2.minutes.ago, title: "Admin alert")
    with_preview_users(@member, @admin) do
      sign_in_as(@admin)
      body = listing(@admin)
      assert_equal [ own.id.to_s ], body.fetch("items").map { |item| item.fetch("id") }
      assert_equal [ 1, 1 ], body.values_at("unread", "total")
      assert_not_includes response.body, "Member alert"
    end
  end

  test "marking one as read changes only that notification of the signed-in account and answers the new counts" do
    first = notify(@member, at: 2.minutes.ago)
    second = notify(@member, at: 1.minute.ago)
    foreign = notify(@other, at: 1.minute.ago)
    with_preview_users(@member, @other) do
      sign_in_as(@member)
      assert_equal({ "account" => @member.id.to_s, "unread" => 1, "total" => 2, "changed" => 1 }, command(web_preview_api_notification_read_path(first), user: @member))
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert first.reload.read?
      assert_not second.reload.read?
      read_at = first.read_at
      assert_equal 0, command(web_preview_api_notification_read_path(first), user: @member).fetch("changed")
      assert_equal read_at, first.reload.read_at

      command(web_preview_api_notification_read_path(foreign), user: @member)
      assert_response :not_found
      assert_equal({ "error" => "not_found" }, response.parsed_body)
      assert_not foreign.reload.read?
      [ "0", "01", "1e3", "#{second.id}x" ].each do |bad|
        post "/preview/api/v1/notifications/#{bad}/read", headers: account_headers(@member), as: :json
        assert_response :not_found, bad
      end
      assert_not second.reload.read?
    end
  end

  test "a stored alert of a type this version does not know is listed and can still be marked read" do
    unknown = notify(@member, at: 1.minute.ago)
    unknown.update_column(:notification_type, "future_kind")
    with_preview_users(@member) do
      sign_in_as(@member)
      assert_equal [ "future_kind" ], listing(@member).fetch("items").map { |item| item.fetch("type") }
      assert_equal({ "account" => @member.id.to_s, "unread" => 0, "total" => 1, "changed" => 1 }, command(web_preview_api_notification_read_path(unknown), user: @member))
      assert unknown.reload.read?
    end
  end

  test "mark all as read and clear all change only what the page had shown, never a newer alert or another account's" do
    older = notify(@member, at: 3.minutes.ago)
    shown = notify(@member, at: 2.minutes.ago)
    foreign = notify(@other, at: 2.minutes.ago)
    newer = notify(@member, at: 1.minute.ago, type: "request_failed", title: "Request Failed")
    with_preview_users(@member, @other) do
      sign_in_as(@member)
      assert_equal({ "account" => @member.id.to_s, "unread" => 1, "total" => 3, "changed" => 2 }, command(web_preview_api_notifications_read_path, user: @member, through: shown.id.to_s))
      assert [ older, shown ].all? { |notification| notification.reload.read? }
      assert_not newer.reload.read?
      assert_not foreign.reload.read?

      assert_equal({ "account" => @member.id.to_s, "unread" => 1, "total" => 1, "changed" => 2 }, command(web_preview_api_notifications_clear_path, user: @member, through: shown.id.to_s))
      assert_equal [ newer.id ], @member.notifications.reload.map(&:id)
      assert Notification.exists?(foreign.id)

      assert_equal 1, command(web_preview_api_notifications_clear_path, user: @member, through: newer.id.to_s).fetch("changed")
      assert_equal [ 0, 0 ], response.parsed_body.values_at("unread", "total")
      assert Notification.exists?(foreign.id)
    end
  end

  test "mark all and clear all refuse a missing or malformed boundary without writing" do
    kept = notify(@member, at: 1.minute.ago)
    with_preview_users(@member) do
      sign_in_as(@member)
      [ {}, { through: "" }, { through: "0" }, { through: "-1" }, { through: 5 }, { through: [ kept.id.to_s ] }, { through: "#{kept.id}.5" } ].each do |body|
        [ web_preview_api_notifications_read_path, web_preview_api_notifications_clear_path ].each do |path|
          assert_equal({ "error" => "invalid_request" }, command(path, user: @member, **body), "#{path} #{body}")
          assert_response :bad_request
        end
      end
      assert Notification.exists?(kept.id)
      assert_not kept.reload.read?
    end
  end

  test "every write needs the page's CSRF token and the account the page was opened for" do
    kept = notify(@member, at: 1.minute.ago)
    with_preview_users(@member, @other) do
      sign_in_as(@member)
      with_forgery_protection do
        token = csrf_token
        writes = [ [ web_preview_api_notification_read_path(kept), {} ], [ web_preview_api_notifications_read_path, { through: kept.id.to_s } ], [ web_preview_api_notifications_clear_path, { through: kept.id.to_s } ] ]
        writes.each do |path, body|
          [ account_headers(@member), account_headers(@member).merge("X-CSRF-Token" => "forged") ].each do |headers|
            post path, params: body, headers: headers, as: :json
            assert_response :unprocessable_entity, path
            assert_equal({ "error" => "invalid_csrf" }, response.parsed_body)
          end
          post path, params: body, headers: account_headers(@other).merge("X-CSRF-Token" => token), as: :json
          assert_response :unauthorized, path
          assert_equal({ "error" => "account_changed" }, response.parsed_body)
        end
        assert Notification.exists?(kept.id)
        assert_not kept.reload.read?
        post web_preview_api_notifications_clear_path, params: { through: kept.id.to_s }, headers: account_headers(@member).merge("X-CSRF-Token" => token), as: :json
        assert_response :success
        assert_not Notification.exists?(kept.id)
      end
    end
  end

  test "a reply for a different account than the page's is refused without data" do
    notify(@member, at: 1.minute.ago, title: "Private alert")
    with_preview_users(@member, @other) do
      sign_in_as(@member)
      preview_get web_preview_api_notifications_path, user: @other
      assert_response :unauthorized
      assert_equal({ "error" => "account_changed" }, response.parsed_body)
      assert_not_includes response.body, "Private alert"
    end
  end

  test "signed out, unlisted and preview-off browsers get no notifications and change nothing" do
    kept = notify(@member, at: 1.minute.ago, title: "Private alert")
    with_preview_users(@member) do
      preview_get web_preview_api_notifications_path, user: @member
      assert_response :unauthorized
      assert_equal({ "error" => "signed_out" }, response.parsed_body)
      get web_preview_notifications_path
      assert_redirected_to new_session_path
    end
    with_preview_users(@other) do
      sign_in_as(@member)
      preview_get web_preview_api_notifications_path, user: @member
      assert_response :not_found
      assert_not_includes response.body, "Private alert"
      command(web_preview_api_notifications_clear_path, user: @member, through: kept.id.to_s)
      assert_response :not_found
      get web_preview_notifications_path
      assert_response :not_found
    end
    with_env(WebPreview::Access::VARIABLE => nil) do
      preview_get web_preview_api_notifications_path, user: @member
      assert_response :not_found
      command(web_preview_api_notification_read_path(kept), user: @member)
      assert_response :not_found
    end
    assert Notification.exists?(kept.id)
    assert_not kept.reload.read?
  end

  test "the warm shell serves the notifications address to listed accounts" do
    with_preview_users(@member) do
      sign_in_as(@member)
      get web_preview_notifications_path
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_select "script#shelfarr-boot"
    end
  end

  test "the classic address sends a listed account to the warm inbox and keeps the classic page for everyone else" do
    notify(@member, at: 1.minute.ago, title: "Classic alert")
    sign_in_as(@member)
    with_preview_users(@member) do
      get notifications_path
      assert_redirected_to web_preview_notifications_path
    end
    with_preview_users(@other) do
      get notifications_path
      assert_response :success
      assert_select "h3", "Classic alert"
    end
    with_env(WebPreview::Access::VARIABLE => nil) do
      get notifications_path
      assert_response :success
      assert_select "h3", "Classic alert"
    end
  end

  test "a classic action's confirmation stays on the classic page instead of being lost in a redirect" do
    notify(@member, at: 1.minute.ago)
    sign_in_as(@member)
    with_preview_users(@member) do
      post mark_all_read_notifications_path
      assert_redirected_to notifications_path
      follow_redirect!
      assert_response :success
      assert_includes response.body, "All notifications marked as read."
      get notifications_path
      assert_redirected_to web_preview_notifications_path
    end
  end
end
