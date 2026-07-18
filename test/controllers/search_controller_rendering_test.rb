# frozen_string_literal: true

require "test_helper"

class SearchControllerRenderingTest < ActionController::TestCase
  tests SearchController

  setup do
    @request.host = "www.example.com"
  end

  test "render_search_results_stream renders loading provider names" do
    @controller.instance_variable_set(:@query, "dune")

    html = @controller.send(
      :render_search_results_stream,
      results: [],
      loading: true,
      pending_providers: %w[openlibrary google_books],
      completed_providers: [],
      error: nil
    )

    assert_includes html, "Searching metadata providers"
    assert_includes html, "Waiting for Open Library and Google Books"
  end

  test "render_search_results_stream renders result update state" do
    @controller.instance_variable_set(:@query, "dune")

    html = @controller.send(
      :render_search_results_stream,
      results: [ candidate ],
      loading: true,
      pending_providers: %w[google_books],
      completed_providers: %w[openlibrary],
      error: nil
    )

    assert_includes html, "1 result"
    assert_includes html, "Still checking Google Books"
    assert_includes html, "Updating"
    assert_includes html, "Open Library"
  end

  test "render_search_results_stream renders errors" do
    @controller.instance_variable_set(:@query, "dune")

    html = @controller.send(
      :render_search_results_stream,
      results: [],
      loading: false,
      pending_providers: [],
      completed_providers: [],
      error: "Search failed. Please try again."
    )

    assert_includes html, "Search failed. Please try again."
  end

  test "with_relative_url_root reapplies the captured prefix and restores the prior SCRIPT_NAME afterward" do
    @controller.instance_variable_set(:@relative_url_root, "/books")

    # Simulates SCRIPT_NAME having reverted on the shared env since the
    # prefix was captured at the top of #stream_results (e.g. once whatever
    # mounted the app under /books is done touching this request).
    @request.set_header("SCRIPT_NAME", "")

    observed_script_name = nil
    @controller.send(:with_relative_url_root) { observed_script_name = @request.script_name }

    assert_equal "/books", observed_script_name
    assert_equal "", @request.script_name
  end

  test "audiobookshelf_matches_for returns placeholders without library items" do
    LibraryItem.destroy_all

    matches = @controller.send(:audiobookshelf_matches_for, [ candidate ])

    assert_equal [ [] ], matches
  end

  test "provider_names humanizes known and unknown providers" do
    assert_equal(
      [ "Open Library", "Google Books", "Custom Provider" ],
      @controller.send(:provider_names, %w[openlibrary google_books custom_provider])
    )
  end

  private

  def candidate
    MetadataSearch::Candidate.new(
      canonical_key: "openlibrary:OL_DUNE_W",
      title: "Dune",
      author: "Frank Herbert",
      year: 1965,
      description: nil,
      cover_url: nil,
      series_name: nil,
      series_position: nil,
      has_ebook: nil,
      has_audiobook: nil,
      sources: [
        {
          source: "openlibrary",
          source_id: "OL_DUNE_W",
          source_name: "Open Library",
          source_url: "https://openlibrary.org/works/OL_DUNE_W",
          work_id: "openlibrary:OL_DUNE_W"
        }
      ],
      editions: [],
      confidence: 70
    )
  end
end
