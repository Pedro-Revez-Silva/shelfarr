# frozen_string_literal: true

require "test_helper"

class AndroidUpdates::ConfigurationTest < ActiveSupport::TestCase
  def config(env)
    AndroidUpdates::Configuration.new(env)
  end

  test "offers the release channel from the official catalog by default" do
    configuration = config({})

    assert_equal %w[release], configuration.channels
    assert_equal AndroidUpdates::Configuration::DEFAULT_CATALOG_URL, configuration.catalog_uri.to_s
    assert configuration.default_source?
    assert_not configuration.misconfigured?
    assert configuration.enabled?("release")
    assert_not configuration.enabled?("development")
    assert_equal "https://github.com", configuration.source_label
  end

  test "development is offered only when listed explicitly" do
    assert_equal %w[release development], config("ANDROID_UPDATE_CHANNELS" => "development, release").channels
    assert_equal %w[development], config("ANDROID_UPDATE_CHANNELS" => " Development ").channels
  end

  test "an empty or none channel list turns the feature off without an error" do
    [ "", " ", "none", "off" ].each do |value|
      configuration = config("ANDROID_UPDATE_CHANNELS" => value)

      assert_empty configuration.channels, value.inspect
      assert_not configuration.any_enabled?
      assert_not configuration.misconfigured?
    end
  end

  test "an unknown channel disables everything and explains why" do
    configuration = config("ANDROID_UPDATE_CHANNELS" => "release,beta")

    assert_empty configuration.channels
    assert configuration.misconfigured?
    assert_match "ANDROID_UPDATE_CHANNELS", configuration.error
  end

  test "a custom catalog must be a clean https json URL" do
    good = config("ANDROID_UPDATE_CATALOG_URL" => "https://Updates.Example.org:8443/shelfarr/catalog.json")
    assert_not good.misconfigured?
    assert_not good.default_source?
    assert_equal "updates.example.org", good.catalog_uri.host
    assert_equal "https://updates.example.org:8443", good.source_label

    [
      "http://updates.example.org/catalog.json",
      "https://user:secret@updates.example.org/catalog.json",
      "https://updates.example.org/catalog.json?token=abc",
      "https://updates.example.org/catalog.json#fragment",
      "https://updates.example.org/a/../catalog.json",
      "https://updates.example.org/a/%2e%2e/catalog.json",
      "https://updates.example.org/catalog.txt",
      "file:///etc/catalog.json",
      "not a url",
      "https://updates.example.org/#{'a' * 2100}.json"
    ].each do |url|
      configuration = config("ANDROID_UPDATE_CATALOG_URL" => url)

      assert configuration.misconfigured?, url
      assert_empty configuration.channels, url
      assert_not_includes configuration.error, "secret"
    end
  end

  test "a blank catalog URL falls back to the official catalog" do
    assert config("ANDROID_UPDATE_CATALOG_URL" => " ").default_source?
  end

  test "maps each channel to its exact package" do
    configuration = config({})

    assert_equal "org.shelfarr.app", configuration.package_for("release")
    assert_equal "org.shelfarr.app.debug", configuration.package_for("development")
  end
end
