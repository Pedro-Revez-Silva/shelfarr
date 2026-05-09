# frozen_string_literal: true

require "test_helper"

class Integrations::CommandProcessorTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "processes status command for a user" do
    result = Integrations::CommandProcessor.call(
      command: "/status",
      arguments: "",
      user: @user,
      origin: { created_via: "telegram" }
    )

    assert_includes result.text, "Latest Shelfarr requests"
    assert_empty result.search_results
  end

  test "processes search command with reusable search result metadata" do
    search_result = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_COMMAND_SEARCH_123W",
      title: "Command Search Book",
      author: "Command Author",
      description: nil,
      year: 2024,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )

    MetadataService.stub(:search, [ search_result ]) do
      result = Integrations::CommandProcessor.call(
        command: "/search",
        arguments: "command",
        user: @user,
        origin: { created_via: "telegram" }
      )

      assert_includes result.text, "Command Search Book"
      assert_equal [ search_result ], result.search_results
    end
  end

  test "processes request command through shared request creation" do
    details = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_COMMAND_REQUEST_123W",
      title: "Command Request Book",
      author: "Command Author",
      description: nil,
      year: 2024,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )

    MetadataService.stub(:book_details, details) do
      assert_difference "Request.count", 1 do
        result = Integrations::CommandProcessor.call(
          command: "/request",
          arguments: "openlibrary:OL_COMMAND_REQUEST_123W ebook",
          user: @user,
          origin: { created_via: "telegram", external_source: "telegram" }
        )

        assert_includes result.text, "Request created"
      end
    end
  end

  test "returns help text for start command" do
    result = Integrations::CommandProcessor.call(
      command: "/start",
      arguments: "",
      user: @user,
      origin: {}
    )

    assert_includes result.text, "/search"
    assert_empty result.search_results
  end

  test "returns usage for blank search and invalid request" do
    search = Integrations::CommandProcessor.call(command: "/search", arguments: "", user: @user, origin: {})
    request = Integrations::CommandProcessor.call(command: "/request", arguments: "work pdf", user: @user, origin: {})

    assert_includes search.text, "Usage: /search"
    assert_includes request.text, "Usage: /request"
  end

  test "returns friendly messages for empty search and metadata failures" do
    MetadataService.stub(:search, []) do
      result = Integrations::CommandProcessor.call(command: "/search", arguments: "missing", user: @user, origin: {})
      assert_includes result.text, "No results found"
    end

    MetadataService.stub(:search, ->(*) { raise MetadataService::Error, "bad" }) do
      result = Integrations::CommandProcessor.call(command: "/search", arguments: "bad", user: @user, origin: {})
      assert_equal "Search failed. Try again later.", result.text
    end
  end

  test "status reports no requests for user without requests" do
    user = User.create!(
      name: "No Requests",
      username: "no_requests",
      password: "Password123!",
      password_confirmation: "Password123!"
    )

    result = Integrations::CommandProcessor.call(command: "/status", arguments: "", user: user, origin: {})

    assert_equal "No requests found.", result.text
  end

  test "unknown command returns help hint" do
    result = Integrations::CommandProcessor.call(command: "/bogus", arguments: "", user: @user, origin: {})

    assert_equal "Unknown command. Use /help for available commands.", result.text
  end
end
