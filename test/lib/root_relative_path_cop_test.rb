# frozen_string_literal: true

require "test_helper"
require "open3"

class RootRelativePathCopTest < ActiveSupport::TestCase
  test "Ruby URL arguments include root paths and distinguish filesystem paths and labels" do
    assert_lint "app/controllers/lint_fixture_controller.rb", <<~SOURCE, [ 3, 4, 5, 6 ]
      class LintFixtureController
        def index
          redirect_to "/"
          redirect_to "/?q=x"
          helpers.link_to "Home", "/"
          redirect_to "/search" + "?q=x"
          send_file "/var/books/book.epub"
          file_path = "/var/books/book.epub"
          render json: { path: "/var/books/book.epub" }
          helpers.link_to "/search", search_path
          redirect_to request.script_name + "/search"
          redirect_to "#{'#{request.script_name}'}/search"
          redirect_to "//catalog.example/search"
        end
      end
    SOURCE
  end

  test "ERB detects real URL strings without linting comments or link labels" do
    assert_lint "app/views/lint_fixture.html.erb", <<~SOURCE, [ 1, 2, 3, 4, 5, 15, 16 ]
      <a href="/">Home</a>
      <%= link_to "Search", "/search" %>
      <%= button_to "Sign in", "/auth/oidc" %>
      <%= link_to "/search", class: "nav" do %>Search<% end %>
      <%= link_to("/search") { "Search" } %>
      <%= link_to "/search", search_path %>
      <%= link_to "/search", { controller: "search" } %>
      <!-- <a href="/search">Example</a> -->
      <%# link_to "Search", "/search" %>
      <% # link_to "Search", "/search" %>
      <% name = "example" # link_to "Search", "/search" %>
      <%= link_to "Search", search_path %>
      <%= image_tag public_asset_path("images/no-cover.svg") %>
      <a href="//catalog.example/search">External</a>
      <%= link_to book.title, "/library" %>
      <script>fetch("/search")</script>
      <p>Example: fetch("/search")</p>
      <p>Example: href="/search"</p>
      <!-- <%= link_to "Search", "/search" %> -->
    SOURCE
  end

  test "JavaScript checks navigation and fetch URLs while excluding comments and example strings" do
    assert_lint "app/javascript/lint_fixture.js", <<~JAVASCRIPT, [ 1, 2, 3, 4, 5, 6 ]
      fetch("/?q=x")
      location = "/"
      window.location.replace("/search")
      location.assign("/profile")
      Turbo.visit("/library")
      const path = "/library"
      // fetch("/search")
      /* location = "/profile" */
      const example = 'Example: fetch("/search")'
      const message = "/help"
      text.replace("/search", "")
      fetch("//catalog.example/search")
      fetch("https://catalog.example/search")
      location = "#anchor"
    JAVASCRIPT
  end

  private

  def assert_lint(path, source, lines)
    output, errors, status = Open3.capture3(
      Rails.root.join("bin/rubocop").to_s, "--only", "Shelfarr/RootRelativePath",
      "--force-exclusion", "--cache", "false", "--format", "json", "--fail-level", "warning",
      "--stdin", path, stdin_data: source
    )
    assert_empty errors
    assert_equal 1, status.exitstatus, output
    offenses = JSON.parse(output).fetch("files").flat_map { |file| file.fetch("offenses") }
    assert_equal lines, offenses.map { |offense| offense.dig("location", "start_line") }
    assert offenses.all? { |offense| offense.fetch("cop_name") == "Shelfarr/RootRelativePath" }
  end
end
