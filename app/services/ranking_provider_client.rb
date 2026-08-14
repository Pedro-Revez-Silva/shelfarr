# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

class RankingProviderClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class ResponseError < Error; end

  Ranking = Data.define(:candidate_id, :rank_score, :match_evidence)

  MAX_RESPONSE_BYTES = 10.megabytes
  HEALTH_CHECK_TIMEOUT_SECONDS = 10
  SCHEMA_VERSION = 1

  NETWORK_ERRORS = [
    SocketError, EOFError, IOError, Errno::ECONNREFUSED, Errno::ECONNRESET,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Net::OpenTimeout, Net::ReadTimeout,
    OpenSSL::SSL::SSLError
  ].freeze

  def initialize(provider)
    @provider = provider
  end

  def rank(request, search_results)
    response = post_json("v1/rank", ranking_payload(request, search_results))
    parse_rankings(response)
  end

  def test_connection
    endpoint = validate_endpoint!("health")
    timeout = [ provider.timeout_seconds, HEALTH_CHECK_TIMEOUT_SECONDS ].min
    response = start_http(endpoint, read_timeout: timeout) do |http|
      http.request(build_request(Net::HTTP::Get, endpoint.uri))
    end

    response.is_a?(Net::HTTPSuccess)
  rescue Error, *NETWORK_ERRORS
    false
  end

  private

  attr_reader :provider

  def ranking_payload(request, search_results)
    {
      schema_version: SCHEMA_VERSION,
      task: "candidate_ranking",
      media: media_payload(request.book),
      context: request_context(request),
      preferences: ranking_preferences(request.book),
      candidates: Array(search_results).map { |result| candidate_payload(result) }
    }
  end

  def media_payload(book)
    {
      type: "book",
      format: book.book_type,
      title: book.title,
      release_year: book.year,
      release_date: book.release_date&.iso8601,
      language: book.language,
      contributors: contributor_payload(book),
      relationships: relationship_payload(book),
      identifiers: identifier_payload(book),
      attributes: {
        content_kind: book.content_kind,
        publisher: book.publisher,
        description: book.description,
        issue_number: book.issue_number,
        metadata_source: book.metadata_source
      }.compact
    }.compact
  end

  def contributor_payload(book)
    [
      ({ role: "author", name: book.author } if book.author.present?),
      ({ role: "narrator", name: book.narrator } if book.narrator.present?)
    ].compact
  end

  def relationship_payload(book)
    return [] if book.series.blank?

    [ { type: "series", name: book.series, position: book.series_position }.compact ]
  end

  def identifier_payload(book)
    {
      isbn: Array(book.isbn).compact_blank,
      open_library_work: Array(book.open_library_work_id).compact_blank,
      open_library_edition: Array(book.open_library_edition_id).compact_blank,
      google_books: Array(book.google_books_id).compact_blank,
      hardcover: Array(book.hardcover_id).compact_blank,
      comic_vine: Array(book.comic_vine_id).compact_blank
    }.reject { |_key, values| values.empty? }
  end

  def request_context(request)
    collection = if request.collection_id.present? || request.collection_title.present?
      {
        source: request.collection_source,
        id: request.collection_id,
        title: request.collection_title
      }.compact
    end

    {
      request_id: request.id.to_s,
      language: request.effective_language,
      scope: request.request_scope,
      collection: collection
    }.compact
  end

  def ranking_preferences(book)
    format_preferences = SettingsService.format_preferences_for(book.book_type)

    {
      preferred_download_types: SettingsService.preferred_download_types,
      approved_formats: format_preferences[:approved_formats],
      rejected_formats: format_preferences[:rejected_formats],
      preferred_formats: format_preferences[:preferred_formats],
      prefer_single_file: format_preferences[:prefer_single_file],
      prefer_higher_bitrate: format_preferences[:prefer_higher_bitrate],
      minimum_seeders: SettingsService.get(:auto_select_min_seeders, default: 1)
    }
  end

  # Deliberately excludes download, magnet, info, and provider-payload URLs.
  def candidate_payload(search_result)
    {
      candidate_id: search_result.id.to_s,
      title: search_result.title,
      source: search_result.source,
      indexer: search_result.indexer,
      download_type: search_result.download_type,
      size_bytes: search_result.size_bytes,
      seeders: search_result.seeders,
      leechers: search_result.leechers,
      published_at: search_result.published_at&.iso8601,
      detected_language: search_result.detected_language,
      detected_formats: search_result.detected_extensions,
      audiobook_structure: search_result.audiobook_structure,
      audio_bitrate_kbps: search_result.audio_bitrate_kbps,
      application_score: search_result.confidence_score,
      application_score_breakdown: search_result.score_breakdown
    }.compact
  end

  def parse_rankings(body)
    rankings = body.is_a?(Hash) ? body.fetch("rankings", nil) : nil
    unless rankings.is_a?(Array)
      raise ResponseError, "#{provider.name} returned an invalid rankings list"
    end

    rankings.filter_map do |item|
      next unless item.is_a?(Hash)

      candidate_id = item["candidate_id"].to_s.presence
      rank_score = normalize_rank_score(item["rank_score"])
      next if candidate_id.blank? || rank_score.nil?

      Ranking.new(
        candidate_id: candidate_id,
        rank_score: rank_score,
        match_evidence: item["match_evidence"]
      )
    end
  end

  def post_json(path, payload)
    endpoint = validate_endpoint!(path)
    response_body = nil
    response = start_http(endpoint, read_timeout: provider.timeout_seconds) do |http|
      request = build_request(Net::HTTP::Post, endpoint.uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)

      http.request(request) do |res|
        response_body = read_capped_body(res)
      end
    end

    raise ResponseError, "#{provider.name} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response_body.to_s)
  rescue JSON::ParserError => e
    raise ResponseError, "#{provider.name} returned invalid JSON: #{e.message}"
  rescue *NETWORK_ERRORS => e
    raise ConnectionError, "Failed to connect to #{provider.name}: #{e.message}"
  end

  def validate_endpoint!(path)
    OutboundUrlGuard.validate!(
      "#{provider.url}/#{path}",
      allow_private: provider.allow_private_network?
    )
  rescue OutboundUrlGuard::BlockedUrlError => e
    raise ConnectionError, "Refused to contact #{provider.name}: #{e.message}"
  end

  def start_http(endpoint, read_timeout:, &block)
    Net::HTTP.start(
      endpoint.host,
      endpoint.port,
      use_ssl: endpoint.use_ssl?,
      ipaddr: endpoint.ipaddr,
      open_timeout: [ read_timeout, 10 ].min,
      read_timeout: read_timeout,
      &block
    )
  end

  def build_request(request_class, uri)
    request = request_class.new(uri)
    request["User-Agent"] = "Shelfarr/1.0"
    request["Authorization"] = "Bearer #{provider.api_key}" if provider.api_key.present?
    request
  end

  def read_capped_body(response)
    declared_length = response["Content-Length"].presence&.to_i
    if declared_length && declared_length > MAX_RESPONSE_BYTES
      raise ResponseError, "#{provider.name} response exceeds #{MAX_RESPONSE_BYTES / 1.megabyte} MB limit"
    end

    body = +""
    response.read_body do |chunk|
      body << chunk
      if body.bytesize > MAX_RESPONSE_BYTES
        raise ResponseError, "#{provider.name} response exceeds #{MAX_RESPONSE_BYTES / 1.megabyte} MB limit"
      end
    end
    body
  end

  def normalize_rank_score(value)
    score = Integer(value, exception: false)
    score if score&.between?(0, 100)
  end
end
