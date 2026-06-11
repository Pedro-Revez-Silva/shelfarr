# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

class CustomAcquisitionProviderClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class ResponseError < Error; end

  MAX_RESPONSE_BYTES = 10.megabytes
  HEALTH_CHECK_TIMEOUT_SECONDS = 10

  DOWNLOAD_TYPE_ALIASES = {
    "direct" => %w[direct http https file],
    "torrent" => %w[torrent magnet],
    "usenet" => %w[usenet nzb]
  }.freeze

  Result = Data.define(
    :provider_result_id, :title, :author, :file_type, :language, :size_bytes,
    :download_type, :download_url, :magnet_url, :info_url, :published_at,
    :availability, :payload
  ) do
    def available?
      availability.blank? || availability == "available"
    end

    def downloadable?
      available?
    end
  end

  Acquisition = Data.define(:download_type, :direct_url, :magnet_url, :nzb_url, :payload)

  def self.normalize_download_type(value)
    normalized = value.to_s.strip.downcase
    return nil if normalized.blank?

    DOWNLOAD_TYPE_ALIASES.each do |canonical, aliases|
      return canonical if aliases.include?(normalized)
    end

    normalized
  end

  def initialize(provider)
    @provider = provider
  end

  def search(request)
    response = post_json("search", search_payload(request))
    parse_search_results(response)
  end

  def acquire(search_result)
    response = post_json("acquire", acquire_payload(search_result))
    parse_acquisition(response)
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

  NETWORK_ERRORS = [
    SocketError, EOFError, IOError, Errno::ECONNREFUSED, Errno::ECONNRESET,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Net::OpenTimeout, Net::ReadTimeout,
    OpenSSL::SSL::SSLError
  ].freeze

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

    unless response.is_a?(Net::HTTPSuccess)
      raise ResponseError, "#{provider.name} returned HTTP #{response.code}"
    end

    parse_json(response_body)
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

  def parse_json(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError => e
    raise ResponseError, "#{provider.name} returned invalid JSON: #{e.message}"
  end

  def search_payload(request)
    book = request.book

    {
      query: [ book.title, book.author ].compact_blank.join(" "),
      request: {
        id: request.id,
        language: request.effective_language
      },
      book: {
        id: book.id,
        title: book.title,
        author: book.author,
        book_type: book.book_type,
        year: book.year,
        language: book.language,
        isbn: book.isbn,
        open_library_work_id: book.open_library_work_id,
        open_library_edition_id: book.open_library_edition_id,
        hardcover_id: book.hardcover_id
      }.compact
    }
  end

  def acquire_payload(search_result)
    {
      provider_result_id: search_result.provider_result_id,
      result: search_result_payload(search_result),
      request: {
        id: search_result.request_id,
        language: search_result.request&.effective_language
      },
      book: {
        id: search_result.request&.book_id,
        title: search_result.request&.book&.title,
        author: search_result.request&.book&.author,
        book_type: search_result.request&.book&.book_type
      }.compact
    }
  end

  def search_result_payload(search_result)
    {
      id: search_result.id,
      title: search_result.title,
      source: search_result.source,
      provider_result_id: search_result.provider_result_id,
      provider_payload: search_result.provider_payload
    }
  end

  def parse_search_results(body)
    results = case body
    when Array
      body
    when Hash
      body.fetch("results", [])
    else
      raise ResponseError, "#{provider.name} returned an invalid search response"
    end

    unless results.is_a?(Array)
      raise ResponseError, "#{provider.name} returned an invalid search results list"
    end

    results.filter_map do |item|
      parse_search_result(item)
    end
  end

  def parse_search_result(item)
    return unless item.is_a?(Hash)

    data = item
    provider_result_id = data["id"].presence || data["provider_result_id"].presence || data["guid"].presence
    title = data["title"].to_s.strip
    return if provider_result_id.blank? || title.blank?
    direct_url = data["direct_url"].presence
    nzb_url = data["nzb_url"].presence
    download_url = data["download_url"].presence || direct_url || nzb_url
    magnet_url = data["magnet_url"].presence
    download_type = self.class.normalize_download_type(data["download_type"].presence || data["type"].presence)
    download_type ||= infer_download_type(direct_url:, nzb_url:, magnet_url:)
    availability = normalize_availability(data["availability"].presence || "available")
    payload = data.merge(
      "download_type" => download_type,
      "availability" => availability
    )

    Result.new(
      provider_result_id: provider_result_id.to_s,
      title: title,
      author: data["author"].presence,
      file_type: data["file_type"].presence || data["format"].presence,
      language: data["language"].presence,
      size_bytes: integer_or_nil(data["size_bytes"]),
      download_type: download_type,
      download_url: download_url,
      magnet_url: magnet_url,
      info_url: data["info_url"].presence,
      published_at: time_or_nil(data["published_at"]),
      availability: availability,
      payload: payload
    )
  end

  def parse_acquisition(body)
    unless body.is_a?(Hash)
      raise ResponseError, "#{provider.name} returned an invalid acquire response"
    end

    data = body
    download_type = self.class.normalize_download_type(data["download_type"].presence || data["type"].presence)
    direct_url = data["direct_url"].presence || data["download_url"].presence
    magnet_url = data["magnet_url"].presence
    nzb_url = data["nzb_url"].presence

    download_type ||= "direct" if direct_url.present?
    download_type ||= "torrent" if magnet_url.present?
    download_type ||= "usenet" if nzb_url.present?

    unless valid_acquisition?(download_type, direct_url:, magnet_url:, nzb_url:)
      raise ResponseError, "#{provider.name} did not return an acquireable artifact"
    end

    Acquisition.new(download_type:, direct_url:, magnet_url:, nzb_url:, payload: data)
  end

  def valid_acquisition?(download_type, direct_url:, magnet_url:, nzb_url:)
    case download_type
    when "direct"
      direct_url.present?
    when "torrent"
      magnet_url.present? || direct_url.present?
    when "usenet"
      nzb_url.present? || direct_url.present?
    else
      false
    end
  end

  def infer_download_type(direct_url:, nzb_url:, magnet_url:)
    return "direct" if direct_url.present?
    return "torrent" if magnet_url.present?
    return "usenet" if nzb_url.present?

    nil
  end

  def normalize_availability(value)
    value.to_s.strip.downcase.presence
  end

  def integer_or_nil(value)
    Integer(value, exception: false)
  end

  def time_or_nil(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
