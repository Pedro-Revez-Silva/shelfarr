# frozen_string_literal: true

require "test_helper"

class SearchResultSnapshotTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @user = users(:one)
    @lock_parent = Dir.mktmpdir("search-result-snapshot-locks")
    SearchResultSnapshot.lock_root = Pathname(@lock_parent).join("private")
  end

  teardown do
    Rails.cache = @original_cache
    SearchResultSnapshot.reset_lock_root!
    FileUtils.remove_entry(@lock_parent) if @lock_parent && File.exist?(@lock_parent)
  end

  test "stores bounded plain candidate data and restores the aggregate" do
    token = SearchResultSnapshot.create(
      user: @user,
      query: "dune",
      content_kind: "book",
      provider_count: 4
    )
    results = (SearchResultSnapshot::MAX_RESULTS + 5).times.map { |index| candidate(index) }

    snapshot = SearchResultSnapshot.write(
      user: @user,
      id: token,
      query: "dune",
      content_kind: "book",
      results: results,
      complete: true,
      failed_providers: %w[google_books],
      provider_count: 4
    )
    fetched = SearchResultSnapshot.fetch(
      user: @user,
      id: token,
      query: "dune",
      content_kind: "book"
    )
    cached = Rails.cache.read("search_result_snapshot:v3:#{@user.id}")
    payload = JSON.parse(cached)

    assert_instance_of SearchResultSnapshot::Snapshot, snapshot
    assert_equal SearchResultSnapshot::MAX_RESULTS, fetched.results.size
    assert_equal "Book 0", fetched.results.first.title
    assert_equal "openlibrary:work-0", fetched.results.first.work_id
    assert fetched.complete
    assert_equal %w[google_books], fetched.failed_providers
    assert plain_cache_data?(payload)
    assert_operator cached.bytesize, :<=, SearchResultSnapshot::MAX_PAYLOAD_BYTES
  end

  test "keeps three snapshots and evicts only the oldest" do
    tokens = %w[one two three four].map do |query|
      SearchResultSnapshot.create(user: @user, query: query, content_kind: "book", provider_count: 1)
    end

    assert_nil SearchResultSnapshot.fetch(user: @user, id: tokens[0], query: "one", content_kind: "book")
    assert_not SearchResultSnapshot.write(
      user: @user,
      id: tokens[0],
      query: "one",
      content_kind: "book",
      results: [ candidate(1) ],
      complete: true,
      failed_providers: [],
      provider_count: 1
    )
    %w[two three four].each_with_index do |query, index|
      assert SearchResultSnapshot.fetch(user: @user, id: tokens[index + 1], query: query, content_kind: "book")
    end

    keys = Rails.cache.instance_variable_get(:@data).keys
    assert_equal [ "search_result_snapshot:v3:#{@user.id}" ], keys
    collection = JSON.parse(Rails.cache.read(keys.first))
    assert_equal tokens.last(3), collection["order"]
  end

  test "concurrent tab snapshots and delayed writes coexist up to quota" do
    queries = %w[alpha beta gamma]
    tokens = {}
    mutex = Mutex.new
    create_threads = queries.map do |query|
      Thread.new do
        token = SearchResultSnapshot.create(user: @user, query: query, content_kind: "book", provider_count: 1)
        mutex.synchronize { tokens[query] = token }
      end
    end
    create_threads.each(&:join)

    write_threads = queries.reverse.map do |query|
      Thread.new do
        SearchResultSnapshot.write(
          user: @user,
          id: tokens.fetch(query),
          query: query,
          content_kind: "book",
          results: [ candidate(queries.index(query)) ],
          complete: true,
          failed_providers: [],
          provider_count: 1
        )
      end
    end
    snapshots = write_threads.map(&:value)

    assert snapshots.all?
    queries.each do |query|
      snapshot = SearchResultSnapshot.fetch(
        user: @user,
        id: tokens.fetch(query),
        query: query,
        content_kind: "book"
      )
      assert snapshot.complete
      assert_equal 1, snapshot.results.size
    end
  end

  test "worst-case fields are deterministically truncated to the serialized byte ceiling" do
    token = SearchResultSnapshot.create(user: @user, query: "large", content_kind: "book", provider_count: 4)
    results = SearchResultSnapshot::MAX_RESULTS.times.map { |index| worst_case_candidate(index) }

    first = SearchResultSnapshot.write(
      user: @user,
      id: token,
      query: "large",
      content_kind: "book",
      results: results,
      complete: true,
      failed_providers: [],
      provider_count: 4
    )
    first_payload = Rails.cache.read("search_result_snapshot:v3:#{@user.id}")
    second = SearchResultSnapshot.write(
      user: @user,
      id: token,
      query: "large",
      content_kind: "book",
      results: results,
      complete: true,
      failed_providers: [],
      provider_count: 4
    )

    assert_operator first_payload.bytesize, :<=, SearchResultSnapshot::MAX_PAYLOAD_BYTES
    assert_operator first.results.size, :<, SearchResultSnapshot::MAX_RESULTS
    assert_equal first.results.map(&:canonical_key), second.results.map(&:canonical_key)
    expected_keys = results.first(first.results.size).map do |result|
      result.canonical_key.byteslice(0, SearchResultSnapshot::MAX_TEXT_BYTES).scrub
    end
    assert_equal expected_keys, first.results.map(&:canonical_key)
  end

  test "three large snapshots receive fair budgets and remain populated after eviction" do
    large_results = SearchResultSnapshot::MAX_RESULTS.times.map { |index| worst_case_candidate(index) }
    tokens = 3.times.map do |index|
      SearchResultSnapshot.create(user: @user, query: "large-#{index}", content_kind: "book", provider_count: 4)
    end
    tokens.each_with_index do |token, index|
      assert SearchResultSnapshot.write(
        user: @user,
        id: token,
        query: "large-#{index}",
        content_kind: "book",
        results: large_results,
        complete: true,
        failed_providers: [],
        provider_count: 4
      )
    end

    cached = Rails.cache.read("search_result_snapshot:v3:#{@user.id}")
    assert_operator cached.bytesize, :<=, SearchResultSnapshot::MAX_PAYLOAD_BYTES
    collection = JSON.parse(cached)
    counts = []
    tokens.each_with_index do |token, index|
      snapshot = SearchResultSnapshot.fetch(
        user: @user,
        id: token,
        query: "large-#{index}",
        content_kind: "book"
      )
      counts << snapshot.results.size
      assert_operator snapshot.results.size, :>, 0
      assert_operator JSON.generate(collection.dig("snapshots", token)).bytesize,
        :<=, SearchResultSnapshot::MAX_SNAPSHOT_BYTES
    end
    assert_equal 1, counts.uniq.size

    fourth = SearchResultSnapshot.create(user: @user, query: "large-3", content_kind: "book", provider_count: 4)
    assert SearchResultSnapshot.write(
      user: @user,
      id: fourth,
      query: "large-3",
      content_kind: "book",
      results: large_results,
      complete: true,
      failed_providers: [],
      provider_count: 4
    )

    assert_nil SearchResultSnapshot.fetch(user: @user, id: tokens.first, query: "large-0", content_kind: "book")
    retained = [ tokens[1], tokens[2], fourth ]
    retained.each_with_index do |token, index|
      snapshot = SearchResultSnapshot.fetch(
        user: @user,
        id: token,
        query: "large-#{index + 1}",
        content_kind: "book"
      )
      assert_operator snapshot.results.size, :>, 0
    end
    final_cached = Rails.cache.read("search_result_snapshot:v3:#{@user.id}")
    final_collection = JSON.parse(final_cached)
    assert_equal retained, final_collection["order"]
    assert_operator final_cached.bytesize, :<=, SearchResultSnapshot::MAX_PAYLOAD_BYTES
  end

  test "pathological numerics are rejected without suppressing later results" do
    huge_integer = 1 << 3_400_000
    custom_numeric = Class.new(Numeric) do
      def to_i
        raise "must not convert"
      end

      def to_s
        raise "must not stringify"
      end
    end.new
    token = SearchResultSnapshot.create(user: @user, query: "numbers", content_kind: "book", provider_count: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    snapshot = SearchResultSnapshot.write(
      user: @user,
      id: token,
      query: "numbers",
      content_kind: "book",
      results: [
        candidate(0, year: huge_integer),
        candidate(1, year: 2026),
        candidate(2, year: custom_numeric),
        candidate(3, year: Float::INFINITY)
      ],
      complete: true,
      failed_providers: [],
      provider_count: 1
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2.0
    assert_equal [ nil, 2026, nil, nil ], snapshot.results.map(&:year)
    assert_equal [ "Book 0", "Book 1", "Book 2", "Book 3" ], snapshot.results.map(&:title)
    assert_operator Rails.cache.read("search_result_snapshot:v3:#{@user.id}").bytesize,
      :<=, SearchResultSnapshot::MAX_PAYLOAD_BYTES
  end

  test "a candidate that exceeds the remaining fair budget does not suppress a later valid candidate" do
    target_token = SearchResultSnapshot.create(user: @user, query: "target", content_kind: "book", provider_count: 1)

    snapshot = SearchResultSnapshot.write(
      user: @user,
      id: target_token,
      query: "target",
      content_kind: "book",
      results: [ worst_case_candidate(998), worst_case_candidate(999), candidate(1) ],
      complete: true,
      failed_providers: [],
      provider_count: 1
    )

    assert_equal [ "x" * SearchResultSnapshot::MAX_TEXT_BYTES, "Book 1" ], snapshot.results.map(&:title)
  end

  test "rejects foreign users and mismatched query or content kind" do
    token = SearchResultSnapshot.create(user: @user, query: "dune", content_kind: "book", provider_count: 1)
    SearchResultSnapshot.write(
      user: @user,
      id: token,
      query: "dune",
      content_kind: "book",
      results: [ candidate(1) ],
      complete: true,
      failed_providers: [],
      provider_count: 1
    )

    assert_nil SearchResultSnapshot.fetch(user: users(:two), id: token, query: "dune", content_kind: "book")
    assert_nil SearchResultSnapshot.fetch(user: @user, id: token, query: "foundation", content_kind: "book")
    assert_nil SearchResultSnapshot.fetch(user: @user, id: token, query: "dune", content_kind: "graphic")
    assert_nil SearchResultSnapshot.fetch(user: @user, id: "not-a-token", query: "dune", content_kind: "book")
  end

  test "expires snapshots and bounds page numbers" do
    token = SearchResultSnapshot.create(user: @user, query: "dune", content_kind: nil, provider_count: 1)

    travel SearchResultSnapshot::TTL + 1.second do
      assert_nil SearchResultSnapshot.fetch(user: @user, id: token, query: "dune", content_kind: nil)
    end

    assert_equal 1, SearchResultSnapshot.normalize_page(nil)
    assert_equal 1, SearchResultSnapshot.normalize_page(-5)
    assert_equal SearchResultSnapshot::MAX_PAGES, SearchResultSnapshot.normalize_page(100)
  end

  test "cache failures return safe misses" do
    failing_cache = Class.new do
      def read(*)
        raise IOError, "cache unavailable"
      end

      def write(*)
        raise IOError, "cache unavailable"
      end
    end.new
    Rails.cache = failing_cache

    assert_nil SearchResultSnapshot.create(user: @user, query: "dune", content_kind: nil, provider_count: 1)
    assert_nil SearchResultSnapshot.fetch(user: @user, id: "a" * 32, query: "dune", content_kind: nil)
    assert_not SearchResultSnapshot.write(
      user: @user,
      id: "a" * 32,
      query: "dune",
      content_kind: nil,
      results: [],
      complete: true,
      failed_providers: [],
      provider_count: 1
    )
  end

  test "mutations use one persistent flock and release it after failure" do
    real_lock = FileCopyService.method(:with_private_lock)
    lock_calls = 0
    wrapper = lambda do |path, root:, **options, &block|
      lock_calls += 1
      real_lock.call(path, root: root, **options, &block)
    end

    FileCopyService.stub(:with_private_lock, wrapper) do
      token = SearchResultSnapshot.create(user: @user, query: "locked", content_kind: "book", provider_count: 1)
      assert SearchResultSnapshot.write(
        user: @user,
        id: token,
        query: "locked",
        content_kind: "book",
        results: [ candidate(1) ],
        complete: true,
        failed_providers: [],
        provider_count: 1
      )

      working_cache = Rails.cache
      begin
        Rails.cache = Class.new do
          def read(*) = nil
          def write(*) = raise(IOError, "cache unavailable")
        end.new
        assert_nil SearchResultSnapshot.create(user: @user, query: "failed", content_kind: "book", provider_count: 1)
      ensure
        Rails.cache = working_cache
      end
    end

    assert_equal 3, lock_calls
    lock_path = snapshot_lock_path
    acquired = FileCopyService.with_private_lock(lock_path.to_s, root: SearchResultSnapshot.lock_root.to_s, nonblock: true) do
      true
    end
    assert acquired
    assert File.file?(lock_path)
  end

  private

  def candidate(index, year: 2000 + (index % 20))
    MetadataSearch::Candidate.new(
      canonical_key: "openlibrary:work-#{index}",
      title: "Book #{index}",
      author: "Author #{index}",
      year: year,
      description: "Description #{index}",
      cover_url: "https://example.com/covers/#{index}.jpg",
      series_name: nil,
      series_position: nil,
      has_ebook: true,
      has_audiobook: nil,
      sources: [ {
        source: "openlibrary",
        source_id: "work-#{index}",
        source_name: "Open Library",
        source_url: "https://openlibrary.org/works/work-#{index}",
        work_id: "openlibrary:work-#{index}"
      } ],
      editions: [],
      confidence: 70
    )
  end

  def snapshot_lock_path
    digest = Digest::SHA256.hexdigest(@user.id.to_s)
    Pathname(SearchResultSnapshot.lock_root).join("#{digest}.lock")
  end

  def worst_case_candidate(index)
    text = "x" * SearchResultSnapshot::MAX_TEXT_BYTES
    sources = SearchResultSnapshot::MAX_SOURCES.times.map do |source_index|
      {
        source: text,
        source_id: "#{index}-#{source_index}-#{text}",
        source_name: text,
        source_url: "https://example.com/#{text}",
        work_id: "source:#{index}-#{source_index}-#{text}"
      }
    end
    editions = SearchResultSnapshot::MAX_EDITIONS.times.map do |edition_index|
      {
        source: text,
        source_id: "#{index}-#{edition_index}-#{text}",
        isbn_10: text,
        isbn_13: text,
        publisher: text,
        year: text,
        page_count: text,
        resource_kind: text
      }
    end

    MetadataSearch::Candidate.new(
      canonical_key: "key-#{index}-#{text}",
      title: text,
      author: text,
      year: 2026,
      description: text,
      cover_url: "https://example.com/#{text}",
      series_name: text,
      series_position: text,
      has_ebook: true,
      has_audiobook: true,
      sources: sources,
      editions: editions,
      confidence: 100,
      classification_evidence: Array.new(SearchResultSnapshot::MAX_LIST_VALUES, text),
      categories: Array.new(SearchResultSnapshot::MAX_LIST_VALUES, text),
      subjects: Array.new(SearchResultSnapshot::MAX_LIST_VALUES, text),
      collection_source: text,
      collection_id: text,
      collection_title: text,
      issue_number: text,
      release_date: text
    )
  end

  def plain_cache_data?(value)
    case value
    when Hash
      value.all? { |key, item| (key.is_a?(String) || key.is_a?(Symbol)) && plain_cache_data?(item) }
    when Array
      value.all? { |item| plain_cache_data?(item) }
    when String, Numeric, TrueClass, FalseClass, NilClass
      true
    else
      false
    end
  end
end
