# frozen_string_literal: true

require "test_helper"

class AndroidUpdates::SourcePolicyTest < ActiveSupport::TestCase
  setup do
    @official = AndroidUpdates::Configuration.new({}).source_policy
    @custom = AndroidUpdates::Configuration.new(
      "ANDROID_UPDATE_CATALOG_URL" => "https://updates.example.org:8443/shelfarr/catalog.json"
    ).source_policy
  end

  def uri(value)
    URI.parse(value)
  end

  test "official APKs must be Shelfarr GitHub release assets" do
    assert @official.allowed_artifact?(uri("https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.apk"))

    [
      "https://github.com/someone-else/shelfarr/releases/download/v1/app.apk",
      "https://github.com/Pedro-Revez-Silva/shelfarr/archive/app.apk",
      "http://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.apk",
      "https://github.com:8443/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.apk",
      "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.apk?x=1",
      "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/../../../evil/app.apk",
      "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/%2e%2e/app.apk",
      "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.zip",
      "https://user@github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.apk",
      "https://objects.githubusercontent.com/app.apk",
      "https://evil.example/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.apk"
    ].each { |value| assert_not @official.allowed_artifact?(uri(value)), value }
  end

  test "official redirects may reach only GitHub's release asset hosts" do
    assert @official.allowed_redirect?(uri("https://release-assets.githubusercontent.com/github-production-release-asset/1/abc?sig=x&exp=1"))
    assert @official.allowed_redirect?(uri("https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/abc?X-Amz=1"))
    assert @official.allowed_redirect?(uri("https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v2/app.apk"))

    [
      "http://release-assets.githubusercontent.com/asset",
      "https://release-assets.githubusercontent.com:444/asset",
      "https://githubusercontent.com.evil.example/asset",
      "https://raw.githubusercontent.com/asset",
      "https://github.com/other/repo/releases/download/v1/app.apk",
      "https://169.254.169.254/latest/meta-data"
    ].each { |value| assert_not @official.allowed_redirect?(uri(value)), value }
    assert_not @official.allow_private_network?
  end

  test "custom sources stay on their exact https origin" do
    assert @custom.allowed_artifact?(uri("https://updates.example.org:8443/any/where/app.apk"))
    assert @custom.allowed_redirect?(uri("https://updates.example.org:8443/mirror/app.apk?signature=1"))
    assert @custom.allowed_catalog?(uri("https://updates.example.org:8443/shelfarr/catalog.json"))

    [
      "https://updates.example.org/any/app.apk",
      "https://other.example.org:8443/app.apk",
      "http://updates.example.org:8443/app.apk",
      "https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/v1/app.apk"
    ].each do |value|
      assert_not @custom.allowed_artifact?(uri(value)), value
      assert_not @custom.allowed_redirect?(uri(value)), value
    end
    assert_not @custom.allowed_catalog?(uri("https://updates.example.org:8443/other.json"))
    assert @custom.allow_private_network?
  end

  test "clean paths reject empty, dot and encoded separator segments" do
    assert AndroidUpdates::SourcePolicy.clean_path?("/a/b.apk")
    [ "a/b", "/a//b", "/a/./b", "/a/../b", "/a/%2F/b", "/a/%5cb", "/a\\b", "/a/%00", "/a/" ].each do |path|
      assert_not AndroidUpdates::SourcePolicy.clean_path?(path), path
    end
  end
end
