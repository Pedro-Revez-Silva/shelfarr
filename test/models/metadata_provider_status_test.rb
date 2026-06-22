# frozen_string_literal: true

require "test_helper"

class MetadataProviderStatusTest < ActiveSupport::TestCase
  test "for_provider creates unknown status once" do
    status = MetadataProviderStatus.for_provider("google_books")

    assert_equal "unknown", status.status
    assert_equal status, MetadataProviderStatus.for_provider("google_books")
  end

  test "record_success clears failure state" do
    status = MetadataProviderStatus.create!(
      provider: "openlibrary",
      status: "rate_limited",
      rate_limited_until: 10.minutes.from_now,
      last_error: "too many requests",
      failure_count: 2
    )

    status.record_success!

    assert_equal "healthy", status.status
    assert_nil status.rate_limited_until
    assert_nil status.last_error
    assert_equal 0, status.failure_count
    assert status.last_success_at.present?
  end

  test "record_failure classifies rate limit errors with backoff" do
    status = MetadataProviderStatus.create!(provider: "google_books", status: "healthy")

    status.record_failure!(GoogleBooksClient::RateLimitError.new("quota exceeded"))

    assert_equal "rate_limited", status.status
    assert status.rate_limited_until.future?
    assert_equal "quota exceeded", status.last_error
    assert_equal 1, status.failure_count
    assert_not status.available?
  end

  test "record_failure classifies auth errors without retry backoff" do
    status = MetadataProviderStatus.create!(provider: "hardcover", status: "healthy")

    status.record_failure!(HardcoverClient::AuthenticationError.new("bad token"))

    assert_equal "auth_failed", status.status
    assert_nil status.rate_limited_until
    assert_not status.available?
  end

  test "record_failure classifies google books auth errors" do
    status = MetadataProviderStatus.create!(provider: "google_books", status: "healthy")

    status.record_failure!(GoogleBooksClient::AuthenticationError.new("invalid api key"))

    assert_equal "auth_failed", status.status
    assert_nil status.rate_limited_until
    assert_not status.available?
  end

  test "record_failure classifies connection and generic errors" do
    connection_status = MetadataProviderStatus.create!(provider: "openlibrary", status: "healthy")
    generic_status = MetadataProviderStatus.create!(provider: "other", status: "healthy")

    connection_status.record_failure!(OpenLibraryClient::ConnectionError.new("timeout"))
    generic_status.record_failure!(StandardError.new("unknown"))

    assert_equal "down", connection_status.status
    assert connection_status.rate_limited_until.future?
    assert_equal "degraded", generic_status.status
    assert generic_status.rate_limited_until.future?
  end

  test "clear_after_credential_change resets auth failed state" do
    status = MetadataProviderStatus.create!(
      provider: "google_books",
      status: "auth_failed",
      last_error: "invalid api key",
      failure_count: 2
    )

    status.clear_after_credential_change!

    assert_equal "unknown", status.status
    assert_nil status.last_error
    assert_nil status.rate_limited_until
    assert_equal 0, status.failure_count
    assert status.available?
  end

  test "clear_after_credential_change_for_settings resets affected providers" do
    google_status = MetadataProviderStatus.create!(provider: "google_books", status: "auth_failed")
    hardcover_status = MetadataProviderStatus.create!(provider: "hardcover", status: "auth_failed")
    openlibrary_status = MetadataProviderStatus.create!(provider: "openlibrary", status: "healthy")

    MetadataProviderStatus.clear_after_credential_change_for_settings!([ "google_books_api_key" ])

    assert_equal "unknown", google_status.reload.status
    assert_equal "auth_failed", hardcover_status.reload.status
    assert_equal "healthy", openlibrary_status.reload.status
  end

  test "expired rate limit is available again" do
    status = MetadataProviderStatus.create!(provider: "google_books", status: "rate_limited", rate_limited_until: 1.minute.ago)

    assert_not status.rate_limited?
    assert status.available?
  end
end
