# frozen_string_literal: true

# Builds Hardcover GraphQL responses shaped like the real API (field names
# and nesting follow the selections in Hardcover::Queries, which are
# validated against Hardcover's published schema) and routes stubbed
# requests by GraphQL operation name.
module HardcoverTestHelper
  GRAPHQL_URL = HardcoverClient::BASE_URL
  RATE_LIMIT_HEADERS = {
    "Content-Type" => "application/json",
    "RateLimit-Policy" => %("Free";q=60;w=60;burst=10, "daily";q=5000;w=86400),
    "RateLimit" => %("Free";r=9;t=0, "daily";r=4990;t=43200)
  }.freeze

  def hardcover_book(id:, title: "Book #{id}", author: "Ada Writer", author_id: 501, role: nil, release_date: "2021-04-06",
    users_count: 100, canonical_id: nil, compilation: false, audio: true, ebook: true, series: nil, position: nil,
    extra_contributors: [])
    {
      "id" => id,
      "title" => title,
      "description" => "Description of #{title}",
      "release_date" => release_date,
      "release_year" => release_date&.first(4)&.to_i,
      "users_count" => users_count,
      "rating" => 4.12,
      "compilation" => compilation,
      "canonical_id" => canonical_id,
      "created_at" => "2023-02-01T12:00:00",
      "cached_image" => { "id" => id * 10, "url" => "https://assets.hardcover.app/books/#{id}/cover.jpg", "color" => "#334455", "width" => 400, "height" => 600 },
      "default_audio_edition_id" => audio ? id * 100 + 1 : nil,
      "default_ebook_edition_id" => ebook ? id * 100 + 2 : nil,
      "contributions" => [ { "contribution" => role, "author" => { "id" => author_id, "name" => author } }, *extra_contributors ],
      "featured_book_series" => series ? { "position" => position, "series" => { "id" => 900, "name" => series } } : nil
    }
  end

  def hardcover_list_book_row(book, id:, position: nil, date_added: "2026-09-01T10:00:00+00:00", updated_at: nil)
    { "id" => id, "position" => position, "date_added" => date_added, "updated_at" => updated_at || date_added, "book" => book }
  end

  def hardcover_user_book_row(book, id:, created_at: "2026-09-01T10:00:00.000000+00:00", updated_at: nil)
    { "id" => id, "created_at" => created_at, "updated_at" => updated_at || created_at, "book" => book }
  end

  def hardcover_contribution_row(book, id:, contribution: nil, languages: [ "en" ])
    enriched = book.merge(
      "default_ebook_edition" => languages[0] ? { "language" => { "code2" => languages[0] } } : nil,
      "default_audio_edition" => nil,
      "default_physical_edition" => languages[1] ? { "language" => { "code2" => languages[1] } } : nil
    )
    { "id" => id, "contribution" => contribution, "book" => enriched }
  end

  # Routes stubbed GraphQL calls by operation name, e.g. "ShelfarrWantToRead".
  # Handlers may be a data hash, a [status, body] pair, or a proc receiving
  # the parsed variables and returning either.
  def stub_hardcover_graphql(handlers = nil, headers: RATE_LIMIT_HEADERS, **operation_handlers)
    handlers = (handlers || {}).merge(operation_handlers.transform_keys(&:to_s))
    @hardcover_requests = []
    stub_request(:post, GRAPHQL_URL).to_return do |request|
      payload = JSON.parse(request.body)
      operation = payload["query"].to_s[/query\s+(\w+)/, 1]
      @hardcover_requests << { operation: operation, variables: payload["variables"], authorization: request.headers["Authorization"] }
      handler = handlers.fetch(operation) { raise "Unexpected Hardcover operation #{operation}" }
      result = handler.respond_to?(:call) ? handler.call(payload["variables"] || {}) : handler
      status, body = result.is_a?(Array) ? result : [ 200, { "data" => result } ]
      { status: status, headers: headers, body: body.to_json }
    end
  end

  def hardcover_requests
    @hardcover_requests || []
  end

  def hardcover_operations
    hardcover_requests.map { |request| request[:operation] }
  end

  def with_hardcover_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  def create_hardcover_connection(user, hardcover_user_id: 4242, auth_method: "oauth", access_token: "hc_at_test_#{user.id}",
    refresh_token: "hc_rt_test_#{user.id}", expires_at: 1.week.from_now, username: "reader#{user.id}")
    user.create_hardcover_connection!(
      auth_method: auth_method,
      access_token: access_token,
      refresh_token: auth_method == "oauth" ? refresh_token : nil,
      access_token_expires_at: auth_method == "oauth" ? expires_at : nil,
      granted_scopes: HardcoverIntegration::OAUTH_SCOPES.join(" "),
      hardcover_user_id: hardcover_user_id,
      hardcover_username: username,
      last_verified_at: Time.current
    )
  end

  def create_hardcover_subscription(user, kind: "list", target_id: 77, status: "active", automatic: false, book_types: [ "ebook" ],
    baseline: 2.days.ago, title: "Subscription #{kind}")
    user.hardcover_subscriptions.create!(
      kind: kind,
      hardcover_target_id: kind == "want_to_read" ? nil : target_id,
      title: title,
      status: status,
      automatic: automatic,
      book_types: book_types,
      snapshot_state: "ready",
      snapshot_completed_at: baseline,
      baseline_established_at: status == "draft" ? nil : baseline,
      sync_cursor_at: status == "draft" ? nil : baseline
    )
  end

  def create_hardcover_item(subscription, book_id:, state: "known", title: "Book #{book_id}", **attrs)
    subscription.items.create!({ hardcover_book_id: book_id, title: title, author: "Ada Writer", state: state, first_seen_at: Time.current }.merge(attrs))
  end

  def configure_hardcover_instance_token(token = "instance_test_token")
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_api_token, token)
    HardcoverClient.reset_connection!
  end
end

ActiveSupport.on_load(:active_support_test_case) { include HardcoverTestHelper }
