# frozen_string_literal: true

require "test_helper"

class IndexerClients::ProwlarrSeedCriteriaTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key-12345")
    IndexerClients::Prowlarr.reset_connection!
  end

  teardown do
    IndexerClients::Prowlarr.reset_connection!
  end

  test "returns seed ratio and seed time from indexer fields" do
    VCR.turned_off do
      stub_indexers(
        indexer_definition(
          11,
          fields: [
            { "name" => "torrentBaseSettings.seedRatio", "value" => 1.5 },
            { "name" => "torrentBaseSettings.seedTime", "value" => 72 }
          ]
        )
      )

      assert_equal({ seed_ratio: 1.5, seed_time: 72 }, IndexerClients::Prowlarr.seed_criteria(11))
    end
  end

  test "omits criteria when Prowlarr fields have no value" do
    VCR.turned_off do
      stub_indexers(
        indexer_definition(
          11,
          fields: [
            { "name" => "torrentBaseSettings.seedRatio" },
            { "name" => "torrentBaseSettings.seedTime" }
          ]
        )
      )

      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(11))
    end
  end

  test "returns only the fields that are configured" do
    VCR.turned_off do
      stub_indexers(
        indexer_definition(
          11,
          fields: [
            { "name" => "torrentBaseSettings.seedRatio", "value" => 1.0 },
            { "name" => "torrentBaseSettings.seedTime" }
          ]
        )
      )

      assert_equal({ seed_ratio: 1.0 }, IndexerClients::Prowlarr.seed_criteria(11))
    end
  end

  test "returns empty criteria for an unknown indexer id" do
    VCR.turned_off do
      stub_indexers(indexer_definition(11, fields: [
        { "name" => "torrentBaseSettings.seedRatio", "value" => 1.5 }
      ]))

      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(99))
    end
  end

  test "returns empty criteria for a blank indexer id" do
    VCR.turned_off do
      indexer_stub = stub_indexers(indexer_definition(11))

      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(nil))
      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(""))
      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(" "))
      assert_not_requested indexer_stub
    end
  end

  test "returns empty criteria when Prowlarr is unreachable" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/indexer})
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(11))
    end
  end

  test "returns empty criteria when Prowlarr is not configured" do
    SettingsService.set(:prowlarr_api_key, "")

    VCR.turned_off do
      indexer_stub = stub_request(:get, %r{localhost:9696/api/v1/indexer})

      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(11))
      assert_not_requested indexer_stub
    end
  end

  test "ignores malformed indexer entries and fields" do
    VCR.turned_off do
      stub_indexers(nil, 12, [ "id", 11 ], { "id" => 11, "fields" => "invalid" })

      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(11))
    end
  end

  test "omits non-finite seed values" do
    VCR.turned_off do
      stub_indexers(indexer_definition(11, fields: [
        { "name" => "torrentBaseSettings.seedRatio", "value" => "1e1000" },
        { "name" => "torrentBaseSettings.seedTime", "value" => "1e1000" }
      ]))

      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(11))
    end
  end

  test "omits invalid seed values so the client keeps global limits" do
    VCR.turned_off do
      stub_indexers(
        indexer_definition(
          11,
          fields: [
            { "name" => "torrentBaseSettings.seedRatio", "value" => -5 },
            { "name" => "torrentBaseSettings.seedTime", "value" => -5 }
          ]
        )
      )

      assert_equal({}, IndexerClients::Prowlarr.seed_criteria(11))
    end
  end

  private

  def stub_indexers(*indexers)
    stub_request(:get, %r{localhost:9696/api/v1/indexer})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: indexers.to_json
      )
  end

  def indexer_definition(id, fields: [])
    {
      "id" => id,
      "name" => "Tracker #{id}",
      "fields" => fields
    }
  end
end
