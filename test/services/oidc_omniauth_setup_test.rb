# frozen_string_literal: true

require "test_helper"

class OidcOmniauthSetupTest < ActiveSupport::TestCase
  cover "OidcOmniauthSetup*"

  class FakeStrategy
    attr_reader :options
    attr_accessor :full_host, :callback_path

    def initialize
      @options = {}
      @full_host = "https://www.example.com"
      @callback_path = "/auth/oidc/callback"
    end
  end

  setup do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")
    SettingsService.set(:oidc_scopes, "openid profile email")
  end

  test "sets the OIDC redirect_uri under the relative url root" do
    strategy = FakeStrategy.new
    strategy.full_host = "https://shelf.example.com"
    strategy.callback_path = "/books/auth/oidc/callback"

    OidcOmniauthSetup.call(
      "omniauth.strategy" => strategy,
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "shelf.example.com",
      "SCRIPT_NAME" => "/books"
    )

    assert_equal "https://auth.example.com", strategy.options[:issuer]
    assert_equal "https://shelf.example.com/books/auth/oidc/callback",
      strategy.options.dig(:client_options, :redirect_uri)
  end

  test "keeps the default callback path when the app is not mounted at a prefix" do
    strategy = FakeStrategy.new

    OidcOmniauthSetup.call(
      "omniauth.strategy" => strategy,
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "www.example.com",
      "SCRIPT_NAME" => ""
    )

    assert_equal "https://www.example.com/auth/oidc/callback",
      strategy.options.dig(:client_options, :redirect_uri)
  end

  test "does not build a provider redirect_uri when OIDC is not configured" do
    SettingsService.set(:oidc_enabled, false)
    strategy = FakeStrategy.new

    OidcOmniauthSetup.call(
      "omniauth.strategy" => strategy,
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "shelf.example.com",
      "SCRIPT_NAME" => "/books"
    )

    assert_equal "https://invalid.example.com", strategy.options[:issuer]
    assert_nil strategy.options.dig(:client_options, :redirect_uri)
  end
end
