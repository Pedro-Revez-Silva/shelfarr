# frozen_string_literal: true

require "test_helper"

class HardcoverIntegrationTest < ActiveSupport::TestCase
  # A fresh custom configuration, the way development and production see the
  # keys only config/environments/test.rb sets: reading an unset key returns
  # an empty ActiveSupport::OrderedOptions, not nil.
  def with_custom_config(values = {})
    custom = Rails::Application::Configuration::Custom.new
    values.each { |key, value| custom.public_send(:"#{key}=", value) }
    # A lambda, because Minitest calls any stub value that responds to #call,
    # and a custom configuration responds to every method.
    Rails.configuration.stub(:x, -> { custom }) { yield }
  end

  test "unset timing keys use the code's defaults" do
    with_custom_config do
      assert_kind_of ActiveSupport::OrderedOptions, Rails.configuration.x.hardcover_background_min_interval
      assert_equal HardcoverClient::BACKGROUND_MIN_INTERVAL, HardcoverClient.background_min_interval
      assert_equal Hardcover::ItemImporter::ITEM_GAP, Hardcover::ItemImporter.new.send(:item_gap)
    end
  end

  test "configured timing keys are used, including zero" do
    with_custom_config(hardcover_background_min_interval: 0, hardcover_import_item_gap: 0.25) do
      assert_equal 0.0, HardcoverClient.background_min_interval
      assert_equal 0.25, Hardcover::ItemImporter.new.send(:item_gap)
    end
    with_custom_config(hardcover_background_min_interval: -3, hardcover_import_item_gap: "soon") do
      assert_equal 0.0, HardcoverClient.background_min_interval
      assert_equal Hardcover::ItemImporter::ITEM_GAP, Hardcover::ItemImporter.new.send(:item_gap)
    end
  end

  test "the test environment turns both waits off" do
    assert_equal 0.0, HardcoverClient.background_min_interval
    assert_equal 0.0, Hardcover::ItemImporter.new.send(:item_gap)
  end

  test "with the default configuration background reads are paced and imports run every item" do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:immediate_search_enabled, false)
    credential = HardcoverClient.credential_for_token("hc_at_defaults", budget_key: HardcoverClient.account_budget_key(920))
    stub_hardcover_graphql("ShelfarrMe" => { "me" => [ { "id" => 920 } ] })
    subscription = create_hardcover_subscription(users(:one), kind: "list", automatic: true)
    items = 3.times.map { |index| create_hardcover_item(subscription, book_id: 9_960 + index, state: "queued", book_types: [ "ebook" ]) }

    with_custom_config do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      2.times { HardcoverClient.execute(Hardcover::Queries::ME, {}, credential: credential, background: true) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, HardcoverClient::BACKGROUND_MIN_INTERVAL * 0.9

      importer = Hardcover::ItemImporter.new
      slept = []
      result = importer.stub(:sleep, ->(seconds) { slept << seconds }) { importer.call }
      assert_equal 3, result.requested
      assert_equal [ Hardcover::ItemImporter::ITEM_GAP ] * 2, slept
    end
    assert items.all? { |item| item.reload.requested? }
    assert_equal 2, hardcover_requests.size
  end
end
