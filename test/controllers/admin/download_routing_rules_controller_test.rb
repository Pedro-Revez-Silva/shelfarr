# frozen_string_literal: true

require "test_helper"

class Admin::DownloadRoutingRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
    DownloadRoutingRule.delete_all
    DownloadClient.delete_all
    @client = DownloadClient.create!(
      name: "qBit",
      client_type: "qbittorrent",
      url: "http://localhost:8080",
      username: "admin",
      password: "password"
    )
  end

  test "index renders routing rules" do
    DownloadRoutingRule.create!(
      provider: "prowlarr",
      indexer_name: "MyAnonaMouse",
      download_type: "torrent",
      download_client: @client
    )

    get admin_download_routing_rules_url

    assert_response :success
    assert_includes response.body, "MyAnonaMouse"
  end

  test "create persists routing rule" do
    assert_difference "DownloadRoutingRule.count", 1 do
      post admin_download_routing_rules_url, params: {
        download_routing_rule: {
          provider: "prowlarr",
          indexer_name: "MyAnonaMouse",
          download_type: "torrent",
          download_client_id: @client.id,
          enabled: "1"
        }
      }
    end

    assert_redirected_to admin_download_routing_rules_path
    rule = DownloadRoutingRule.last
    assert_equal "myanonamouse", rule.normalized_indexer_name
  end

  test "update changes routing rule" do
    rule = DownloadRoutingRule.create!(
      provider: "prowlarr",
      indexer_name: "MyAnonaMouse",
      download_type: "torrent",
      download_client: @client
    )

    patch admin_download_routing_rule_url(rule), params: {
      download_routing_rule: {
        indexer_name: "IPTorrents",
        enabled: "0"
      }
    }

    assert_redirected_to admin_download_routing_rules_path
    assert_equal "IPTorrents", rule.reload.indexer_name
    assert_not rule.enabled?
  end

  test "destroy removes routing rule" do
    rule = DownloadRoutingRule.create!(
      provider: "prowlarr",
      indexer_name: "MyAnonaMouse",
      download_type: "torrent",
      download_client: @client
    )

    assert_difference "DownloadRoutingRule.count", -1 do
      delete admin_download_routing_rule_url(rule)
    end

    assert_redirected_to admin_download_routing_rules_path
  end
end
