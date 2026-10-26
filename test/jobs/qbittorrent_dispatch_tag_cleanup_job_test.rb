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
end
