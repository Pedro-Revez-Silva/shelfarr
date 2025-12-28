# frozen_string_literal: true

require "test_helper"

module Admin
  class IssuesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = users(:two)
      @user = users(:one)
      @failed_request = requests(:failed_request)
      @max_retries_exceeded = requests(:max_retries_exceeded)
      sign_in_as(@admin)
    end

    # === Authorization ===

    test "index requires admin" do
      sign_out
      sign_in_as(@user)

      get admin_issues_path
      assert_redirected_to root_path
    end

    test "retry requires admin" do
      sign_out
      sign_in_as(@user)

      post retry_admin_issue_path(@failed_request)
      assert_redirected_to root_path
    end

    test "cancel requires admin" do
      sign_out
      sign_in_as(@user)

      post cancel_admin_issue_path(@failed_request)
      assert_redirected_to root_path
    end

    # === Index ===

    test "index shows requests with issues" do
      get admin_issues_path
      assert_response :success

      assert_select "h1", "Issues"
      assert_select "h3", @failed_request.book.title
      assert_select "h3", @max_retries_exceeded.book.title
    end

    test "index shows empty state when no issues" do
      Request.with_issues.destroy_all

      get admin_issues_path
      assert_response :success

      assert_select "h3", "No issues"
    end

    test "index shows issue description" do
      get admin_issues_path
      assert_response :success

      assert_select ".bg-red-500\\/10", text: /Download failed/
    end

    test "index shows retry count for requests with retries" do
      get admin_issues_path
      assert_response :success

      # Check that the page contains retry count information
      assert_match(/\d+ retr(y|ies)/, response.body)
    end

    # === Retry ===

    test "retry resets request for immediate processing" do
      assert @max_retries_exceeded.attention_needed?
      assert @max_retries_exceeded.not_found?

      post retry_admin_issue_path(@max_retries_exceeded)

      @max_retries_exceeded.reload
      assert @max_retries_exceeded.pending?
      assert_not @max_retries_exceeded.attention_needed?
      assert_nil @max_retries_exceeded.next_retry_at

      assert_redirected_to admin_issues_path
      assert_match(/queued for retry/, flash[:notice])
    end

    test "retry works on failed requests" do
      assert @failed_request.failed?

      post retry_admin_issue_path(@failed_request)

      @failed_request.reload
      assert @failed_request.pending?
      assert_redirected_to admin_issues_path
    end

    # === Cancel ===

    test "cancel marks request as failed permanently" do
      assert @max_retries_exceeded.not_found?

      post cancel_admin_issue_path(@max_retries_exceeded)

      @max_retries_exceeded.reload
      assert @max_retries_exceeded.failed?
      assert_not @max_retries_exceeded.attention_needed?

      assert_redirected_to admin_issues_path
      assert_match(/cancelled/, flash[:notice])
    end

    test "cancel removes request from issues list" do
      issues_count_before = Request.with_issues.count

      post cancel_admin_issue_path(@max_retries_exceeded)

      # The cancelled request should no longer have attention_needed
      # but failed requests are still in with_issues scope
      @max_retries_exceeded.reload
      assert @max_retries_exceeded.failed?
      assert_not @max_retries_exceeded.attention_needed?
    end
  end
end
