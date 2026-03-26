# frozen_string_literal: true

require "test_helper"

class NotificationServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    @request = requests(:pending_request)
    SettingsService.set(:webhook_enabled, true)
    SettingsService.set(:webhook_url, "http://localhost:4567/webhook")
    SettingsService.set(:webhook_events, "request_created,request_completed,request_failed,request_attention")
    clear_enqueued_jobs
  end

  test "request_completed creates notification" do
    assert_difference "Notification.count", 1 do
      NotificationService.request_completed(@request)
    end

    notification = Notification.last
    assert_equal @user, notification.user
    assert_equal @request, notification.notifiable
    assert_equal "request_completed", notification.notification_type
    assert_equal "Book Ready", notification.title
    assert_includes notification.message, @request.book.title
  end

  test "request_completed enqueues outbound webhook delivery" do
    assert_enqueued_with(job: OutboundWebhookDeliveryJob) do
      NotificationService.request_completed(@request)
    end

    enqueued = enqueued_jobs.find { |job| job[:job] == OutboundWebhookDeliveryJob }
    args = enqueued[:args].first.with_indifferent_access
    assert_equal "request_completed", args[:event]
    assert_equal @request.id, args[:request_id]
  end

  test "request_failed creates notification" do
    assert_difference "Notification.count", 1 do
      NotificationService.request_failed(@request)
    end

    notification = Notification.last
    assert_equal "request_failed", notification.notification_type
    assert_equal "Request Failed", notification.title
  end

  test "request_failed enqueues outbound webhook delivery" do
    assert_enqueued_with(job: OutboundWebhookDeliveryJob) do
      NotificationService.request_failed(@request)
    end

    enqueued = enqueued_jobs.find { |job| job[:job] == OutboundWebhookDeliveryJob }
    args = enqueued[:args].first.with_indifferent_access
    assert_equal "request_failed", args[:event]
    assert_equal @request.id, args[:request_id]
  end

  test "request_attention creates notification" do
    assert_difference "Notification.count", 1 do
      NotificationService.request_attention(@request)
    end

    notification = Notification.last
    assert_equal "request_attention", notification.notification_type
    assert_equal "Attention Needed", notification.title
  end

  test "request_created only enqueues outbound webhook delivery" do
    assert_no_difference "Notification.count" do
      assert_enqueued_with(job: OutboundWebhookDeliveryJob) do
        NotificationService.request_created(@request)
      end
    end

    enqueued = enqueued_jobs.find { |job| job[:job] == OutboundWebhookDeliveryJob }
    args = enqueued[:args].first.with_indifferent_access
    assert_equal "request_created", args[:event]
    assert_equal @request.id, args[:request_id]
  end
end
