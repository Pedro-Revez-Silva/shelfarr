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

  test "render_search_results_stream keeps the mounted prefix in chunks rendered after SCRIPT_NAME reverts mid-stream" do
    @controller.instance_variable_set(:@query, "dune")

    @request.set_header("SCRIPT_NAME", "")
    @request.set_header("PATH_INFO", "/books/search/results/stream")

    mounted = Rack::URLMap.new(
      "/books" => lambda do |env|
        # #stream_results captures @relative_url_root once, up front, from
        # whatever prefix mounted the app for this request (e.g. Rack::URLMap
        # under RAILS_RELATIVE_URL_ROOT).
        @controller.instance_variable_set(:@relative_url_root, env[Rack::SCRIPT_NAME])

        @controller.send(
          :render_search_results_stream,
          results: [],
          loading: true,
          pending_providers: %w[openlibrary],
          completed_providers: [],
          error: nil
        )

        [ 200, {}, [] ]
      end
    )
    mounted.call(@request.env)

    # ActionController::Live returns control up the Rack stack as soon as the
    # first chunk commits, well before later chunks render on the background
    # thread. Whatever mounted the app at /books is done touching SCRIPT_NAME
    # on this (shared) env by then, so it can revert -- reproduce that here.
    @request.set_header("SCRIPT_NAME", "")

    second_chunk = @controller.send(
      :render_search_results_stream,
      results: [ candidate ],
      loading: false,
      pending_providers: [],
      completed_providers: %w[openlibrary],
      error: nil
    )

    assert_match %r{href="/books/search/details\?}, second_chunk
    assert_no_match %r{href="/search/details\?}, second_chunk
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
