# frozen_string_literal: true

require "test_helper"

class DownloadRoutingRuleTest < ActiveSupport::TestCase
  Result = Struct.new(:source, :indexer, :download_type, keyword_init: true) do
    def from_indexer?
      source.in?([SearchResult::SOURCE_PROWLARR, SearchResult::SOURCE_JACKETT]) || source.blank?
    end

    def from_jackett?
      source == SearchResult::SOURCE_JACKETT
    end
  end

  setup do
    DownloadRoutingRule.delete_all
    DownloadClient.delete_all
  end

  test "normalizes provider indexer and download type" do
    client = create_client
    rule = DownloadRoutingRule.create!(
      provider: " Prowlarr ",
      indexer_name: "  My   AnonaMouse  ",
      download_type: " Torrent ",
      download_client: client
    )

    assert_equal "prowlarr", rule.provider
    assert_equal "My AnonaMouse", rule.indexer_name
    assert_equal "my anonamouse", rule.normalized_indexer_name
    assert_equal "torrent", rule.download_type
  end

  test "prevents duplicate routes for same provider indexer and download type" do
    create_rule(indexer_name: "MyAnonaMouse")
    duplicate = build_rule(indexer_name: " myanonamouse ")

    refute duplicate.valid?
    assert_includes duplicate.errors[:normalized_indexer_name].join, "already been taken"
  end

  test "allows same indexer to route different download types" do
    create_rule(indexer_name: "Mixed Indexer", download_type: "torrent")
    usenet_client = create_client(name: "SAB", client_type: "sabnzbd", api_key: "key")
    rule = build_rule(indexer_name: "Mixed Indexer", download_type: "usenet", download_client: usenet_client)

    assert rule.valid?
  end

  test "requires a compatible download client" do
    usenet_client = create_client(name: "SAB", client_type: "sabnzbd", api_key: "key")
    rule = build_rule(download_type: "torrent", download_client: usenet_client)

    refute rule.valid?
    assert_includes rule.errors[:download_client].join, "must be a torrent client"
  end

  test "finds enabled route for matching prowlarr result" do
    rule = create_rule(provider: "prowlarr", indexer_name: "MyAnonaMouse", download_type: "torrent")
    result = Result.new(source: SearchResult::SOURCE_PROWLARR, indexer: "myanonamouse", download_type: "torrent")

    assert_equal rule, DownloadRoutingRule.for_result(result)
  end

  test "finds jackett route separately from prowlarr route" do
    jackett_rule = create_rule(provider: "jackett", indexer_name: "Books", download_type: "torrent")
    create_rule(provider: "prowlarr", indexer_name: "Books", download_type: "torrent", download_client: create_client(name: "Other", url: "http://other"))
    result = Result.new(source: SearchResult::SOURCE_JACKETT, indexer: "Books", download_type: "torrent")

    assert_equal jackett_rule, DownloadRoutingRule.for_result(result)
  end

  test "ignores disabled routes" do
    create_rule(indexer_name: "MyAnonaMouse", enabled: false)
    result = Result.new(source: SearchResult::SOURCE_PROWLARR, indexer: "MyAnonaMouse", download_type: "torrent")

    assert_nil DownloadRoutingRule.for_result(result)
  end

  test "does not route direct or blank-indexer results" do
    create_rule(indexer_name: "MyAnonaMouse")

    assert_nil DownloadRoutingRule.for_result(Result.new(source: SearchResult::SOURCE_PROWLARR, indexer: "", download_type: "torrent"))
    assert_nil DownloadRoutingRule.for_result(Result.new(source: SearchResult::SOURCE_PROWLARR, indexer: "MyAnonaMouse", download_type: "direct"))
  end

  private

  def create_rule(**attributes)
    build_rule(**attributes).tap(&:save!)
  end

  def build_rule(**attributes)
    defaults = {
      provider: "prowlarr",
      indexer_name: "MyAnonaMouse",
      download_type: "torrent",
      download_client: create_client
    }
    DownloadRoutingRule.new(defaults.merge(attributes))
  end

  def create_client(name: nil, client_type: "qbittorrent", url: "http://localhost:8080", **attributes)
    name ||= "qBit #{SecureRandom.hex(4)}"
    DownloadClient.create!(
      {
        name: name,
        client_type: client_type,
        url: url
      }.merge(attributes)
    )
  end
end
