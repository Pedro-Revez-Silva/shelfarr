# frozen_string_literal: true

require "test_helper"

class Admin::ActivityLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)

    ActivityLog.create!(action: "user.login", user: @admin)
    ActivityLog.create!(action: "request.created", user: users(:one))
  end

  test "index requires admin" do
    sign_out
    sign_in_as(users(:one))

    get admin_activity_logs_path
    assert_response :redirect
    assert_redirected_to root_path
  end

  test "index shows activity logs" do
    get admin_activity_logs_path
    assert_response :success
    assert_select "h1", "Activity Log"
    assert_select "table"
  end

  test "index filters by user" do
    get admin_activity_logs_path, params: { user_id: @admin.id }
    assert_response :success
  end

  test "index filters by action" do
    get admin_activity_logs_path, params: { action_filter: "user.login" }
    assert_response :success
  end

  test "index filters by date" do
    get admin_activity_logs_path, params: { from: Date.today.to_s }
    assert_response :success
  end
end
