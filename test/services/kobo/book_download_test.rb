# frozen_string_literal: true

require "test_helper"

class Kobo::BookDownloadTest < ActiveSupport::TestCase
  START = "https://storedownloads.kobo.com/download?signature=synthetic"
  FILE = "https://getbook.kobo.com/book.epub?token=synthetic"

  setup do
    @io = StringIO.new(+"".b)
    @download = Kobo::BookDownload.new
  end

  def failure(url = START, expected_size: 5, io: @io)
    assert_raises(Kobo::BookDownload::Error) { @download.call(url, io: io, expected_size: expected_size) }.code
  end

  test "follows only Kobo's file-host redirect and never sends credentials or cookies" do
    stub_request(:get, START).to_return(status: 302, headers: { "Location" => FILE })
    stub_request(:get, FILE).to_return(body: "hello", headers: { "Content-Length" => "5" })
    result = @download.call(START, io: @io, expected_size: 5)
    assert_equal 5, result.bytes
    assert_equal Digest::SHA256.hexdigest("hello"), result.sha256
    assert_equal "hello", @io.string
    [ START, FILE ].each do |url|
      assert_requested(:get, url) { |request| (request.headers.keys.map(&:downcase) & %w[authorization cookie]).empty? }
      assert_requested(:get, url, headers: { "Accept-Encoding" => "identity" })
    end
  end

  test "a relative redirect stays on the same trusted host" do
    stub_request(:get, START).to_return(status: 307, headers: { "Location" => "/download2?signature=synthetic" })
    stub_request(:get, "https://storedownloads.kobo.com/download2?signature=synthetic").to_return(body: "hello")
    assert_equal 5, @download.call(START, io: @io, expected_size: 5).bytes
  end

  test "untrusted starting points and redirects are refused before any request leaves" do
    [ FILE, "http://storedownloads.kobo.com/x", "https://evil.example/x", "https://storedownloads.kobo.com:444/x",
      "https://a:b@storedownloads.kobo.com/x", "not a url" ].each do |url|
      assert_equal "untrusted_host", failure(url)
    end
    [ "https://evil.example/book", "http://getbook.kobo.com/book", "https://getbook.kobo.com.evil.example/b",
      "file:///etc/passwd", "https://169.254.169.254/latest" ].each do |location|
      stub_request(:get, START).to_return(status: 302, headers: { "Location" => location })
      assert_equal "untrusted_host", failure
    end
    assert_not_requested :get, /evil|169\.254|passwd/
  end

  test "redirect loops missing locations and refusals stop with a category" do
    stub_request(:get, START).to_return(status: 302, headers: { "Location" => START })
    assert_equal "download_refused", failure
    stub_request(:get, START).to_return(status: 302)
    assert_equal "download_refused", failure
    { 403 => "download_refused", 404 => "download_refused", 206 => "download_refused",
      429 => "provider_unavailable", 503 => "provider_unavailable" }.each do |status, code|
      stub_request(:get, START).to_return(status: status, body: "synthetic-private-error")
      error = assert_raises(Kobo::BookDownload::Error) { @download.call(START, io: @io, expected_size: 5) }
      assert_equal code, error.code
      assert_not_includes error.message, "synthetic"
    end
    stub_request(:get, START).to_timeout
    assert_equal "provider_unavailable", failure
  end

  test "size must be known, match exactly, and stay within the limit" do
    stub_request(:get, START).to_return(body: "hello", headers: { "Content-Length" => "5" })
    assert_equal "incomplete", failure(expected_size: 6)
    stub_request(:get, START).to_return(body: "hel")
    assert_equal "incomplete", failure(expected_size: 5)
    stub_request(:get, START).to_return(body: "hello world")
    assert_equal "incomplete", failure(expected_size: 5)
    stub_request(:get, START).to_return(body: "x", headers: { "Content-Length" => (Kobo::BookDownload::MAX_BYTES + 1).to_s })
    assert_equal "too_large", failure(expected_size: nil)
    stub_request(:get, START).to_return(body: "hello", headers: { "Content-Encoding" => "gzip" })
    assert_equal "invalid_file", failure
    stub_request(:get, START).to_return(body: "hello", headers: { "Content-Length" => "5" })
    assert_equal 5, @download.call(START, io: StringIO.new(+""), expected_size: nil).bytes
  end

  test "a full disk and a slow transfer fail without claiming completion" do
    stub_request(:get, START).to_return(body: "hello")
    full = Object.new
    def full.write(_) = raise(Errno::ENOSPC)
    assert_equal "storage_full", failure(io: full)
    times = [ 0, Kobo::BookDownload::MAX_SECONDS + 1 ].each
    slow = Kobo::BookDownload.new(clock: -> { times.next })
    assert_equal "timed_out", assert_raises(Kobo::BookDownload::Error) { slow.call(START, io: @io, expected_size: 5) }.code
  end
end
