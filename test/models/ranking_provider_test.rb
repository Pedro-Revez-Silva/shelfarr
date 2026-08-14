# frozen_string_literal: true

require "test_helper"

class RankingProviderTest < ActiveSupport::TestCase
  test "normalizes trailing slash from URL" do
    provider = RankingProvider.create!(name: "Ranker", url: "http://ranker.test/")

    assert_equal "http://ranker.test", provider.url
  end

  test "requires an http or https URL" do
    provider = RankingProvider.new(name: "Ranker", url: "file:///tmp/ranker")

    assert_not provider.valid?
    assert_includes provider.errors[:url], "must be a valid http or https URL"
  end

  test "rejects private network URLs unless explicitly allowed" do
    provider = RankingProvider.new(name: "Ranker", url: "http://localhost:4567")

    assert_not provider.valid?
    assert_match(/private network address/, provider.errors[:url].first)

    provider.allow_private_network = true
    assert provider.valid?, provider.errors.full_messages.join(", ")
  end

  test "orders enabled providers by priority" do
    second = RankingProvider.create!(name: "Second", url: "http://second-ranker.test", priority: 2)
    first = RankingProvider.create!(name: "First", url: "http://first-ranker.test", priority: 1)
    RankingProvider.create!(name: "Disabled", url: "http://disabled-ranker.test", priority: 0, enabled: false)

    assert_equal [ first, second ], RankingProvider.enabled.by_priority.to_a
  end

  test "encrypts api key" do
    provider = RankingProvider.create!(name: "Secure", url: "http://secure-ranker.test", api_key: "secret-ranker-token")

    provider.reload
    assert_equal "secret-ranker-token", provider.api_key
    assert_not_equal "secret-ranker-token", provider.api_key_before_type_cast
  end
end
