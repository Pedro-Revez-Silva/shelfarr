# frozen_string_literal: true

require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
  end

  test "run_health_check requires admin" do
    sign_out
    post admin_run_health_check_url
    assert_response :redirect
  end

  test "run_health_check enqueues job and redirects with notice" do
    assert_enqueued_with(job: HealthCheckJob) do
      post admin_run_health_check_url
    end

    assert_redirected_to admin_root_path
    assert_equal "Health check started. Results will appear shortly.", flash[:notice]
  end

  test "run_health_check redirects with generic alert on failure" do
    HealthCheckJob.stub(:perform_later, ->(*) { raise "Redis connection refused" }) do
      post admin_run_health_check_url
    end

    assert_redirected_to admin_root_path
    assert_equal "Health check failed. Check logs for details.", flash[:alert]
  end
end
