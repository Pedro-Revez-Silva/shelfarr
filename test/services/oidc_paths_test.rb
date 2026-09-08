# frozen_string_literal: true

require "test_helper"

class OidcPathsTest < ActiveSupport::TestCase
  cover "OidcPaths*"

  test "request and callback paths are unprefixed at the application root" do
    assert_equal "/auth/oidc", OidcPaths.request_path
    assert_equal "/auth/oidc/callback", OidcPaths.callback_path
  end

  test "request and callback paths include the mounted script name" do
    assert_equal "/books/auth/oidc", OidcPaths.request_path(script_name: "/books")
    assert_equal "/books/auth/oidc/callback", OidcPaths.callback_path(script_name: "/books")
  end

  test "normalizes relative url root values without a leading slash" do
    assert_equal "/books/auth/oidc", OidcPaths.request_path(relative_url_root: "books")
    assert_equal "/books/auth/oidc/callback", OidcPaths.callback_path(relative_url_root: "books/")
  end

  test "callback_uri includes the relative url root from SCRIPT_NAME" do
    uri = OidcPaths.callback_uri(
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "shelf.example.com",
      "SCRIPT_NAME" => "/books"
    )

    assert_equal "https://shelf.example.com/books/auth/oidc/callback", uri
  end

  test "callback_uri stays at the host root when SCRIPT_NAME is blank" do
    uri = OidcPaths.callback_uri(
      "rack.url_scheme" => "http",
      "HTTP_HOST" => "www.example.com",
      "SCRIPT_NAME" => ""
    )

    assert_equal "http://www.example.com/auth/oidc/callback", uri
  end

  test "callback_uri falls back to RAILS_RELATIVE_URL_ROOT when SCRIPT_NAME is missing" do
    uri = Rails.application.config.stub(:relative_url_root, "/books") do
      OidcPaths.callback_uri(
        "rack.url_scheme" => "https",
        "HTTP_HOST" => "shelf.example.com"
      )
    end

    assert_equal "https://shelf.example.com/books/auth/oidc/callback", uri
  end
end
