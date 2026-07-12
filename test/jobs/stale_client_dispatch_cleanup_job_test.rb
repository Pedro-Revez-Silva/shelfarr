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
end
