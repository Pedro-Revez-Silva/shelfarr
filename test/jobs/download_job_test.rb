# frozen_string_literal: true

require "test_helper"

class DownloadJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    @selected_result = search_results(:selected_result)

    # Create a qBittorrent client
    @client = DownloadClient.create!(
      name: "Test qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )

    # Clear qBittorrent sessions
    Thread.current[:qbittorrent_sessions] = {}

    # Create a queued download
    @download = @request.downloads.create!(
      name: @selected_result.title,
      size_bytes: @selected_result.size_bytes,
      status: :queued
    )
  end

  test "updates download status to downloading on success" do
    VCR.turned_off do
      stub_qbittorrent_success

      DownloadJob.perform_now(@download.id)
      @download.reload

      assert @download.downloading?
      assert_equal @client.id.to_s, @download.download_client_id
      assert_equal "abc123def456", @download.external_id
    end
  end

  test "marks for attention when no search result selected" do
    # Remove the selected result
    @request.search_results.selected.destroy_all

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "No search result selected"
  end

  test "marks for attention when result has no download link" do
    # Replace selected with no-link result
    @request.search_results.selected.destroy_all
    no_link = search_results(:no_link_result)
    no_link.update!(status: :selected)

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "no download link"
  end

  test "marks for attention when no download client configured" do
    @client.destroy!

    DownloadJob.perform_now(@download.id)
    @download.reload
    @request.reload

    assert @download.failed?
    assert @request.attention_needed?
    assert_includes @request.issue_description, "No torrent download client configured"
  end

  test "skips non-queued downloads" do
    @download.update!(status: :downloading)

    DownloadJob.perform_now(@download.id)
    @download.reload

    # Status should not change
    assert @download.downloading?
  end

  test "skips non-existent downloads" do
    assert_nothing_raised do
      DownloadJob.perform_now(999999)
    end
  end

  # Tests for filename handling (URL decoding and sanitization)

  test "sanitize_filename decodes URL-encoded characters" do
    job = DownloadJob.new
    url = "https://example.com/download/Moonshot%20%3A%20inside%20Pfizer%27s%20book.epub"

    filename = job.send(:infer_filename_from_url, url, @selected_result)

    # Should decode %20 to space, %3A to colon, %27 to apostrophe
    assert_includes filename, "Moonshot"
    assert_not_includes filename, "%20"
    assert_not_includes filename, "%3A"
    assert_not_includes filename, "%27"
    assert filename.end_with?(".epub")
  end

  test "sanitize_filename preserves extension when truncating long filenames" do
    job = DownloadJob.new

    # Create a filename that's over 200 characters
    long_name = "A" * 250 + ".epub"
    result = job.send(:sanitize_filename, long_name)

    assert result.length <= 200
    assert result.end_with?(".epub"), "Extension should be preserved after truncation"
  end

  test "sanitize_filename handles filenames under max length" do
    job = DownloadJob.new

    short_name = "Short Book Title.epub"
    result = job.send(:sanitize_filename, short_name)

    assert_equal "Short Book Title.epub", result
  end

  test "sanitize_filename removes invalid characters" do
    job = DownloadJob.new

    name_with_invalid = "Book: A \"Test\" Title?.epub"
    result = job.send(:sanitize_filename, name_with_invalid)

    assert_not_includes result, ":"
    assert_not_includes result, "\""
    assert_not_includes result, "?"
    assert result.end_with?(".epub")
  end

  test "infer_filename_from_url falls back to book metadata when URL has no extension" do
    job = DownloadJob.new
    url = "https://example.com/download/some-file-without-extension"

    filename = job.send(:infer_filename_from_url, url, @selected_result)

    # Should fall back to author - title format
    book = @selected_result.request.book
    assert_includes filename, book.author
    assert_includes filename, book.title
    assert filename.end_with?(".epub") || filename.end_with?(".pdf") || filename.end_with?(".mobi")
  end

  private

  def stub_qbittorrent_success
    # Stub authentication
    stub_request(:post, "http://localhost:8080/api/v2/auth/login")
      .to_return(
        status: 200,
        headers: { "Set-Cookie" => "SID=test_session_id; path=/" },
        body: "Ok."
      )

    # Stub add torrent
    stub_request(:post, "http://localhost:8080/api/v2/torrents/add")
      .to_return(status: 200, body: "Ok.")

    # Stub torrent info query - first call returns empty (before adding),
    # subsequent calls return the new torrent (after adding)
    stub_request(:get, %r{localhost:8080/api/v2/torrents/info})
      .to_return(
        { status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json },
        { status: 200, headers: { "Content-Type" => "application/json" }, body: [{ "hash" => "abc123def456", "name" => "Test Torrent", "progress" => 0, "state" => "downloading", "size" => 1000, "content_path" => "/downloads/Test Torrent" }].to_json }
      )
  end
end
