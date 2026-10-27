# frozen_string_literal: true

require "test_helper"

class QbittorrentDispatchTagCleanupJobTest < ActiveJob::TestCase
  setup do
    DownloadClient.destroy_all
    @client = DownloadClient.create!(
      name: "Tag cleanup qBittorrent",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "adminadmin",
      priority: 0,
      enabled: true
    )
  end

  test "schedules later deletions of an abandoned dispatch tag" do
    tag = "shelfarr-abcdef0123456789"

    freeze_time do
      QbittorrentDispatchTagCleanupJob.schedule(@client.id, tag)

      QbittorrentDispatchTagCleanupJob::CLEANUP_DELAYS.each do |delay|
        assert_enqueued_with(
          job: QbittorrentDispatchTagCleanupJob,
          args: [ @client.id, tag ],
          at: Time.current + delay
        )
      end
    end
  end

  test "deletes an abandoned dispatch tag after authenticating" do
    tag = "shelfarr-abcdef0123456789"
    Thread.current[:qbittorrent_sessions] = {}

    VCR.turned_off do
      login = stub_request(:post, "http://localhost:8080/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=cleanup; path=/" },
          body: "Ok."
        )
      delete_request = stub_request(:post, "http://localhost:8080/api/v2/torrents/deleteTags")
        .with(body: hash_including("tags" => tag))
        .to_return(status: 200, body: "")

      QbittorrentDispatchTagCleanupJob.perform_now(@client.id, tag)

      assert_requested login
      assert_requested delete_request
    end
  end

  test "does not delete a tag that is not a shelfarr dispatch tag" do
    VCR.turned_off do
      delete_request = stub_request(:post, "http://localhost:8080/api/v2/torrents/deleteTags")

      QbittorrentDispatchTagCleanupJob.perform_now(@client.id, "movies")
      QbittorrentDispatchTagCleanupJob.perform_now(@client.id, nil)
      QbittorrentDispatchTagCleanupJob.perform_now(0, "shelfarr-abcdef0123456789")

      assert_not_requested delete_request
    end
  end

  test "does not delete a dispatch tag from a non-qbittorrent client" do
    transmission = DownloadClient.create!(
      name: "Transmission",
      client_type: "transmission",
      url: "http://localhost:9091/transmission/rpc",
      username: "admin",
      password: "adminadmin",
      priority: 1,
      enabled: true
    )

    VCR.turned_off do
      delete_request = stub_request(:post, %r{/api/v2/torrents/deleteTags})

      QbittorrentDispatchTagCleanupJob.perform_now(transmission.id, "shelfarr-abcdef0123456789")

      assert_not_requested delete_request
    end
  end

  test "deletes a dispatch tag after refreshing an expired session" do
    tag = "shelfarr-abcdef0123456789"
    cookies = remember_expired_session

    VCR.turned_off do
      login = stub_login
      delete_request = stub_delete_tags(tag) do |request|
        cookies << request.headers["Cookie"]
        cookies.size == 1 ? 403 : 200
      end

      assert_no_enqueued_jobs only: QbittorrentDispatchTagCleanupJob do
        QbittorrentDispatchTagCleanupJob.perform_now(@client.id, tag)
      end

      assert_requested login, times: 1
      assert_requested delete_request, times: 2
      assert_equal [ "SID=expired", "SID=fresh" ], cookies
      assert_equal "fresh", Thread.current[:qbittorrent_sessions][@client.id][:cookie_value]
    end
  end

  test "retries when an expired session still cannot delete the dispatch tag" do
    tag = "shelfarr-abcdef0123456789"
    remember_expired_session

    VCR.turned_off do
      login = stub_login
      delete_request = stub_delete_tags(tag) { 403 }

      freeze_time do
        assert_enqueued_with(
          job: QbittorrentDispatchTagCleanupJob,
          args: [ @client.id, tag ],
          at: 3.seconds.from_now
        ) do
          QbittorrentDispatchTagCleanupJob.perform_now(@client.id, tag)
        end
      end

      assert_requested login, times: 1
      assert_requested delete_request, times: 2
      assert_nil Thread.current[:qbittorrent_sessions][@client.id][:cookie_value]
    end
  end

  private

  def remember_expired_session
    Thread.current[:qbittorrent_sessions] = {
      @client.id => { cookie_name: "SID", cookie_value: "expired" }
    }
    []
  end

  def stub_login
    stub_request(:post, "http://localhost:8080/api/v2/auth/login")
      .to_return(
        status: 200,
        headers: { "Set-Cookie" => "SID=fresh; path=/" },
        body: "Ok."
      )
  end

  def stub_delete_tags(tag)
    stub_request(:post, "http://localhost:8080/api/v2/torrents/deleteTags")
      .with(body: hash_including("tags" => tag))
      .to_return do |request|
        status = yield(request)
        { status: status, body: status == 200 ? "" : "Forbidden" }
      end
  end
end
