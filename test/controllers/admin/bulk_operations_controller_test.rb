# frozen_string_literal: true

require "test_helper"

class Admin::BulkOperationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
    @failed_request = requests(:failed_request)
    @max_retries_request = requests(:max_retries_exceeded)
  end

  test "retry_selected requires admin" do
    sign_out
    sign_in_as(users(:one))

    post retry_selected_admin_bulk_operations_path, params: { request_ids: [@failed_request.id] }
    assert_response :redirect
    assert_redirected_to root_path
  end

  test "retry_selected retries selected requests" do
    post retry_selected_admin_bulk_operations_path, params: { request_ids: [@failed_request.id, @max_retries_request.id] }

    assert_redirected_to requests_path(attention: "true")
    assert_includes flash[:notice], "2 requests queued for retry"

    assert_equal "pending", @failed_request.reload.status
    assert_equal "pending", @max_retries_request.reload.status
  end

  test "retry_selected handles empty selection" do
    post retry_selected_admin_bulk_operations_path, params: { request_ids: [] }

    assert_redirected_to requests_path(attention: "true")
    assert_includes flash[:notice], "0 requests"
  end

  test "cancel_selected cancels selected requests" do
    SettingsService.set(:webhook_enabled, true)
    SettingsService.set(:webhook_url, "http://localhost:4567/webhook")
    SettingsService.set(:webhook_events, "request_failed")

    assert_enqueued_with(job: OutboundWebhookDeliveryJob) do
      post cancel_selected_admin_bulk_operations_path, params: { request_ids: [@failed_request.id] }
    end

    assert_redirected_to requests_path(attention: "true")
    assert_includes flash[:notice], "1 request cancelled"

    assert_equal "failed", @failed_request.reload.status

    enqueued = enqueued_jobs.find { |job| job[:job] == OutboundWebhookDeliveryJob }
    args = enqueued[:args].first.with_indifferent_access
    assert_equal "request_failed", args[:event]
    assert_equal @failed_request.id, args[:request_id]
  end

  test "retry_all retries all issues" do
    post retry_all_admin_bulk_operations_path

    assert_redirected_to requests_path(attention: "true")
    assert_includes flash[:notice], "queued for retry"

    assert_equal "pending", @failed_request.reload.status
  end
end
