# frozen_string_literal: true

require "test_helper"

class StaleClientDispatchCleanupJobTest < ActiveJob::TestCase
  setup do
    DownloadClient.destroy_all
    @client = DownloadClient.create!(
      name: "Cleanup SABnzbd",
      client_type: "sabnzbd",
      url: "http://localhost:8080",
      api_key: "cleanup-api-key",
      priority: 0,
      enabled: true
    )
  end

  test "removes a stale client dispatch" do
    VCR.turned_off do
      removal = stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including(
          "mode" => "queue",
          "name" => "delete",
          "value" => "SABnzbd_nzo_stale",
          "del_files" => "1"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "status" => true }.to_json
        )

      StaleClientDispatchCleanupJob.perform_now(@client.id, "SABnzbd_nzo_stale")

      assert_requested removal
    end
  end

  test "treats an already absent stale dispatch as cleaned up" do
    VCR.turned_off do
      stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "queue", "name" => "delete"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "status" => false }.to_json
        )
      stub_request(:get, "http://localhost:8080/api")
        .with(query: hash_including("mode" => "history", "name" => "delete"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "status" => false }.to_json
        )
      queue = stub_request(:get, "http://localhost:8080/api")
        .with(query: {
          "mode" => "queue",
          "apikey" => "cleanup-api-key",
          "output" => "json"
        })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "queue" => { "slots" => [] } }.to_json
        )
      history = stub_request(:get, "http://localhost:8080/api")
        .with(query: {
          "mode" => "history",
          "limit" => "50",
          "apikey" => "cleanup-api-key",
          "output" => "json"
        })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "history" => { "slots" => [] } }.to_json
        )

      assert_nothing_raised do
        StaleClientDispatchCleanupJob.perform_now(@client.id, "SABnzbd_nzo_absent")
      end
      assert_requested queue
      assert_requested history
    end
  end

  test "ignores invalid external IDs" do
    StaleClientDispatchCleanupJob.perform_now(@client.id, "https://example.com/?token=secret")

    assert_not_requested :get, %r{localhost:8080}
  end

  test "scheduled cleanup removes a cancelled download that still owns its client id" do
    client = DownloadClient.create!(
      name: "Cancelled owner #{SecureRandom.hex(4)}",
      client_type: :qbittorrent,
      url: "http://127.0.0.1:9",
      enabled: true,
      priority: 4
    )
    book = Book.create!(title: "Finished import still seeding", book_type: :audiobook)
    request = Request.create!(book: book, user: users(:one), status: :processing, attention_needed: true)
    download = request.downloads.create!(
      name: book.title,
      status: :completed,
      download_client: client,
      external_id: "completed-import-job",
      post_processing_job_id: "finished-import-not-queued"
    )
    calls = []
    adapter = Object.new
    adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
      calls << [ external_id, delete_files ]
      raise DownloadClients::Base::ConnectionError, "offline" if calls.size == 1

      true
    end
    adapter.define_singleton_method(:torrent_info) { |_external_id| Object.new }

    DownloadClients::Qbittorrent.stub(:new, adapter) do
      assert_enqueued_jobs 1, only: StaleClientDispatchCleanupJob do
        error = assert_raises(Request::CancellationBlockedError) { request.remove_as_admin! }
        assert_match(/could not confirm/i, error.message)
      end

      assert download.reload.completed?
      assert_nil download.external_id_released_at
      assert Request.exists?(request.id)

      perform_enqueued_jobs
    end

    assert_equal [
      [ "completed-import-job", false ],
      [ "completed-import-job", false ]
    ], calls
  end
end
