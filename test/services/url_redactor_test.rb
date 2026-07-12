# frozen_string_literal: true

require "test_helper"

class UrlRedactorTest < ActiveSupport::TestCase
  test "redacts sensitive query parameters while preserving non-sensitive ones" do
    url = "http://prowlarr:9696/11/download?apikey=secret&file=Atomic+Habits&token=abc123"

    result = UrlRedactor.redact(url)

    assert_equal "http://prowlarr:9696/11/download?apikey=[REDACTED]&file=Atomic+Habits&token=[REDACTED]", result
  end

  test "leaves urls without query strings unchanged" do
    url = "http://example.com/download/test.nzb"

    assert_equal url, UrlRedactor.redact(url)
  end

  test "redacts URL userinfo and fragments" do
    url = "https://alice:password@example.com/download/book.nzb#secret-fragment"

    assert_equal "https://[REDACTED]@example.com/download/book.nzb#[REDACTED]", UrlRedactor.redact(url)
  end

  test "redacts common signed URL parameters case insensitively" do
    url = "https://example.com/download?X-Amz-Credential=credential&X-Amz-Signature=signature&X-Amz-Security-Token=session&file=book"

    assert_equal(
      "https://example.com/download?X-Amz-Credential=[REDACTED]&X-Amz-Signature=[REDACTED]&X-Amz-Security-Token=[REDACTED]&file=book",
      UrlRedactor.redact(url)
    )
  end

  test "Rails parameter filtering hides NZB and persisted download URLs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      nzb_url: "https://example.com/nzb?token=secret",
      download_url: "https://example.com/download?token=secret"
    )

    assert_equal "[FILTERED]", filtered[:nzb_url]
    assert_equal "[FILTERED]", filtered[:download_url]
  end
end
