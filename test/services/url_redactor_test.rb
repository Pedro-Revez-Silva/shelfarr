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
end
