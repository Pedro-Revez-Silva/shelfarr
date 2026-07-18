# frozen_string_literal: true

require "cgi"
require "ipaddr"
require "json"
require "net/http"
require "uri"

class LibationCompanionClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class ResponseError < Error; end
  class BusyError < ResponseError; end
  class NotConfiguredError < Error; end

  TOKEN_FILE_ENV = "SHELFARR_LIBATION_TOKEN_FILE"
  MAX_TOKEN_BYTES = 8.kilobytes
  # Normalized pages contain at most 250 compact records. An 8 MB per-response
  # ceiling leaves generous room for real metadata while preventing one custom
  # companion response from creating a very large Ruby object graph.
  MAX_RESPONSE_BYTES = 8.megabytes
  LIBRARY_PAGE_SIZE = 250
  # A personal Audible library can be large, but accepting an effectively
  # unbounded object graph from a custom companion lets one authenticated peer
  # exhaust both the Rails process and SQLite. Keep this comfortably above the
  # high-volume regression fixture while retaining a finite reconciliation
  # budget.
  MAX_LIBRARY_ITEMS = 100_000
  MAX_LIBRARY_SNAPSHOT_ATTEMPTS = 2
  # Four hundred full pages cover the 100k-title ceiling. Leave room for a
  # short snapshot-consistency retry, but never let a hostile companion turn
  # that item ceiling into tens of thousands of round trips. A caller can
  # simply retry if a genuine maximum-size catalog changes late in the read.
  MAX_LIBRARY_PAGE_REQUESTS = 512
  # JSON/object expansion is substantial in Ruby. This wire budget keeps the
  # retained normalized catalog comfortably below a multi-gigabyte worst case
  # while still accommodating exceptionally large real-world libraries.
  MAX_LIBRARY_AGGREGATE_RESPONSE_BYTES = 128.megabytes
  MAX_ACCOUNTS = 100
  MAX_VERSION_BYTES = 200
  MAX_ACCOUNT_BYTES = 320
  MAX_ACCOUNT_NAME_BYTES = 1.kilobyte
  MAX_LOCALE_BYTES = 32
  MAX_TITLE_BYTES = 4.kilobytes
  MAX_SUBTITLE_BYTES = 4.kilobytes
  MAX_NAME_ENTRIES = 100
  MAX_NAME_BYTES = 1.kilobyte
  MAX_COVER_URL_BYTES = 8.kilobytes
  MAX_LANGUAGE_BYTES = 100
  MAX_FILE_PATH_BYTES = 4.kilobytes
  MAX_TIMESTAMP_BYTES = 128
  MAX_JOB_ERROR_BYTES = 2.kilobytes
  MAX_METADATA_STRING_BYTES = 4.kilobytes
  MAX_DURATION_SECONDS = 10.years.to_i
  MAX_ASIN_BYTES = 10
  ASIN_PATTERN = /\A[A-Z0-9]{10}\z/i
  JOB_ID_PATTERN = /\A[A-Za-z0-9._:-]{1,200}\z/
  MAX_ARTIFACT_PATHS = 100
  MAX_ARTIFACT_PATH_BYTES = 4.kilobytes
  AUTH_SESSION_ID_PATTERN = /\A[A-Za-z0-9._~:-]{1,200}\z/
  AUDIBLE_MARKETPLACES = %w[
    us uk australia canada france germany india italy japan spain
  ].freeze
  AUDIBLE_MARKETPLACE_NAMES = {
    "us" => "United States", "uk" => "United Kingdom",
    "australia" => "Australia", "canada" => "Canada", "france" => "France",
    "germany" => "Germany", "india" => "India", "italy" => "Italy",
    "japan" => "Japan", "spain" => "Spain"
  }.freeze
  AUTH_HOST_SUFFIXES = %w[
    amazon.com amazon.co.uk amazon.com.au amazon.ca amazon.fr amazon.de
    amazon.in amazon.it amazon.co.jp amazon.es audible.com audible.co.uk
    audible.com.au audible.ca audible.fr audible.de audible.in audible.it
    audible.co.jp audible.es
  ].freeze
  SAFE_LIBRARY_METADATA_KEYS = %w[
    bookStatus contentType datePublished hasPdf includedUntil lastDownloaded
    pdfStatus series
  ].freeze

  NETWORK_ERRORS = [
    SocketError, EOFError, IOError, Errno::ECONNREFUSED, Errno::ECONNRESET,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Net::OpenTimeout, Net::ReadTimeout,
    OpenSSL::SSL::SSLError
  ].freeze

  Version = Data.define(:companion_version, :libation_version, :payload)
  Account = Data.define(:account, :locale, :authenticated, :scan_enabled, :name, :payload)
  AuthSession = Data.define(:session_id, :login_url, :expires_at, :authenticated, :payload)
  LibraryEntry = Data.define(
    :external_id, :media_type, :title, :subtitle, :authors, :narrators,
    :cover_url, :language, :duration_seconds, :ownership_type, :purchased_at,
    :active, :downloaded, :file_path, :payload
  )
  CompanionJob = Data.define(:id, :status, :artifact_paths, :error, :payload) do
    def completed?
      status == "completed"
    end

    def failed?
      status == "failed"
    end

    def cancelled?
      status == "cancelled"
    end

    def terminal?
      completed? || failed? || cancelled?
    end
  end

  def initialize(connection)
    @connection = connection
  end

  def token_file_managed?
    ENV[TOKEN_FILE_ENV].present? &&
      connection.url == OwnedLibraryConnection.default_libation_url
  end

  def health
    get_json("/health", authenticated: false)
  end

  def version
    payload = get_json("/version")
    unless payload.is_a?(Hash)
      raise ResponseError, "Libation companion returned an invalid version"
    end

    Version.new(
      companion_version: optional_bounded_string(
        payload["companionVersion"].presence || payload["version"].presence,
        "companion version",
        MAX_VERSION_BYTES
      ),
      libation_version: optional_bounded_string(
        payload["libationVersion"].presence,
        "Libation version",
        MAX_VERSION_BYTES
      ),
      payload: payload
    )
  end

  def accounts
    payload = get_json("/v1/accounts")
    entries = extract_array(payload, "accounts")
    if entries.length > MAX_ACCOUNTS
      raise ResponseError, "Libation companion returned too many Audible accounts"
    end

    entries.map do |entry|
      unless entry.is_a?(Hash)
        raise ResponseError, "Libation companion returned an invalid Audible account"
      end

      account = required_bounded_string(
        entry["account"].presence || entry["id"].presence,
        "Audible account",
        MAX_ACCOUNT_BYTES
      )
      locale = required_bounded_string(entry["locale"], "Audible account locale", MAX_LOCALE_BYTES)

      Account.new(
        account: account,
        locale: locale,
        authenticated: strict_boolean(entry["authenticated"], "account authentication", default: false),
        scan_enabled: strict_boolean(
          entry.fetch("scanEnabled", entry.fetch("scanLibrary", true)),
          "account scan setting",
          default: true
        ),
        name: optional_bounded_string(entry["name"], "Audible account name", MAX_ACCOUNT_NAME_BYTES),
        payload: entry
      )
    end
  end

  def start_auth(account:, locale:)
    account = account.to_s.strip
    locale = locale.to_s.strip.downcase
    raise ArgumentError, "Audible account is required" if account.blank? || account.length > 320
    raise ArgumentError, "Unsupported Audible marketplace" unless AUDIBLE_MARKETPLACES.include?(locale)

    payload = post_json(
      "/v1/auth/start",
      { "account" => account, "locale" => locale }
    )

    if payload["status"].to_s.casecmp("authenticated").zero?
      return AuthSession.new(
        session_id: nil,
        login_url: nil,
        expires_at: nil,
        authenticated: true,
        payload: payload
      )
    end

    session_id = payload["sessionId"].presence
    login_url = payload["loginUrl"].presence
    raise ResponseError, "Libation companion returned an invalid authentication session" if session_id.blank? || login_url.blank?
    unless session_id.to_s.match?(AUTH_SESSION_ID_PATTERN)
      raise ResponseError, "Libation companion returned an invalid authentication session"
    end
    validate_auth_url!(login_url, label: "login")

    AuthSession.new(
      session_id: session_id.to_s,
      login_url: login_url.to_s,
      expires_at: parse_time(payload["expiresAt"]),
      authenticated: false,
      payload: payload
    )
  end

  def complete_auth(session_id:, response_url:)
    session_id = session_id.to_s.strip
    response_url = response_url.to_s.strip
    raise ArgumentError, "Invalid Libation authentication session" unless session_id.match?(AUTH_SESSION_ID_PATTERN)
    validate_auth_url!(response_url, label: "response")

    post_json(
      "/v1/auth/complete",
      { "sessionId" => session_id, "responseUrl" => response_url }
    )
  end

  def start_sync
    parse_job(post_json("/v1/sync", {}))
  end

  def library
    attempts = 0
    budget = build_library_read_budget
    begin
      attempts += 1
      read_library_pages(budget: budget)
    rescue LibrarySnapshotChanged
      retry if attempts < MAX_LIBRARY_SNAPSHOT_ATTEMPTS

      raise ResponseError, "Libation library changed while Shelfarr was reading it; retry the sync"
    end
  end

  def start_backup(asin)
    asin = asin.to_s.strip
    raise ArgumentError, "Invalid Audible ASIN" unless asin.match?(ASIN_PATTERN)

    parse_job(post_json("/v1/backups/#{CGI.escape(asin)}", {}))
  end

  def job(job_id)
    job_id = job_id.to_s.strip
    raise ArgumentError, "Invalid companion job id" unless job_id.match?(JOB_ID_PATTERN)

    parse_job(get_json("/v1/jobs/#{CGI.escape(job_id)}"))
  end

  private

  class LibrarySnapshotChanged < StandardError; end

  class LibraryReadBudget
    def initialize(max_requests:, max_response_bytes:)
      @max_requests = max_requests
      @max_response_bytes = max_response_bytes
      @requests = 0
      @response_bytes = 0
    end

    def record_request!
      @requests += 1
      return if @requests <= @max_requests

      raise ResponseError, "Libation library exceeded the safe page request budget"
    end

    def record_response!(bytes)
      @response_bytes += bytes
      return if @response_bytes <= @max_response_bytes

      raise ResponseError, "Libation library exceeded the safe aggregate response budget"
    end
  end

  attr_reader :connection

  def read_library_pages(budget:)
    offset = 0
    expected_generated_at = nil
    expected_total = nil
    parsed_entries = []
    seen_external_ids = {}

    loop do
      budget.record_request!
      payload = get_json(
        "/v1/library?offset=#{offset}&limit=#{LIBRARY_PAGE_SIZE}",
        response_budget: budget
      )
      unless paged_library_payload?(payload)
        if offset.positive?
          raise ResponseError, "Libation companion changed library response formats mid-read"
        end

        append_library_entries!(
          parsed_entries,
          extract_array(payload, "items", fallback_key: "library"),
          seen_external_ids
        )
        return parsed_entries
      end

      page = validate_library_page!(
        payload,
        requested_offset: offset,
        requested_limit: LIBRARY_PAGE_SIZE
      )
      if expected_generated_at &&
          (page[:generated_at] != expected_generated_at || page[:total] != expected_total)
        raise LibrarySnapshotChanged
      end
      expected_generated_at ||= page[:generated_at]
      expected_total ||= page[:total]
      append_library_entries!(parsed_entries, page[:items], seen_external_ids)

      next_offset = page[:next_offset]
      break unless next_offset

      offset = next_offset
    end

    parsed_entries
  end

  def append_library_entries!(destination, raw_entries, seen_external_ids)
    if raw_entries.length > MAX_LIBRARY_ITEMS ||
        destination.length + raw_entries.length > MAX_LIBRARY_ITEMS
      raise ResponseError, "Libation companion library exceeds the #{MAX_LIBRARY_ITEMS} title limit"
    end

    raw_entries.each do |raw_entry|
      entry = parse_library_entry(raw_entry)
      if seen_external_ids.key?(entry.external_id)
        raise ResponseError, "Libation companion returned a duplicate Audible ASIN"
      end

      seen_external_ids[entry.external_id] = true
      destination << entry
    end
  end

  def paged_library_payload?(payload)
    payload.is_a?(Hash) &&
      (payload.key?("totalItems") || payload.key?("nextOffset") || payload.key?("offset"))
  end

  def validate_library_page!(payload, requested_offset:, requested_limit:)
    items = extract_array(payload, "items")
    offset = strict_integer(payload["offset"], "offset")
    limit = strict_integer(payload["limit"], "limit")
    total = strict_integer(payload["totalItems"], "total item count")
    generated_at = payload["generatedAt"].to_s
    next_offset = payload["nextOffset"]
    next_offset = strict_integer(next_offset, "next offset") unless next_offset.nil?

    unless offset == requested_offset && limit == requested_limit &&
        total.between?(0, MAX_LIBRARY_ITEMS) && generated_at.present?
      raise ResponseError, "Libation companion returned invalid library page metadata"
    end
    if items.length > limit || generated_at.bytesize > MAX_TIMESTAMP_BYTES
      raise ResponseError, "Libation companion returned invalid library page metadata"
    end

    consumed_offset = offset + items.length
    if consumed_offset > total ||
        (next_offset && items.length != limit) ||
        (next_offset && (next_offset != consumed_offset || next_offset <= offset || next_offset > total)) ||
        (next_offset.nil? && consumed_offset != total)
      raise ResponseError, "Libation companion returned an inconsistent library page"
    end

    {
      items: items,
      generated_at: generated_at,
      total: total,
      next_offset: next_offset
    }
  end

  def strict_integer(value, label)
    Integer(value, exception: false) ||
      raise(ResponseError, "Libation companion returned an invalid library #{label}")
  end

  def build_library_read_budget
    LibraryReadBudget.new(
      max_requests: MAX_LIBRARY_PAGE_REQUESTS,
      max_response_bytes: MAX_LIBRARY_AGGREGATE_RESPONSE_BYTES
    )
  end

  def get_json(path, authenticated: true, response_budget: nil)
    request_json(
      Net::HTTP::Get,
      path,
      authenticated: authenticated,
      response_budget: response_budget
    )
  end

  def post_json(path, payload, authenticated: true)
    request_json(Net::HTTP::Post, path, payload: payload, authenticated: authenticated)
  end

  def request_json(request_class, path, payload: nil, authenticated: true, response_budget: nil)
    endpoint = validated_endpoint(path)
    token = bearer_token if authenticated

    response_body = nil
    response = Net::HTTP.start(
      endpoint.host,
      endpoint.port,
      use_ssl: endpoint.use_ssl?,
      ipaddr: endpoint.ipaddr,
      open_timeout: [ connection.timeout_seconds, 10 ].min,
      read_timeout: connection.timeout_seconds
    ) do |http|
      request = request_class.new(endpoint.uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "Shelfarr/1.0"
      request["Authorization"] = "Bearer #{token}" if token.present?
      if payload
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
      end

      http.request(request) do |res|
        response_body = read_capped_body(res)
      end
    end
    response_budget&.record_response!(response_body.bytesize)

    if response.code.to_i == 409
      raise BusyError, "Libation companion is busy with another operation"
    end
    if response.code.to_i == 429
      raise BusyError, "Libation companion queue is full; try again after queued work finishes"
    end
    if response.code.to_i == 422 && path.start_with?("/v1/backups/")
      raise ResponseError, "Libation companion rejected this title as ineligible for backup"
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise ResponseError, "Libation companion returned HTTP #{response.code}"
    end

    parse_json(response_body)
  rescue OutboundUrlGuard::BlockedUrlError => e
    raise ConnectionError, "Refused to contact Libation companion: #{e.message}"
  rescue *NETWORK_ERRORS => e
    raise ConnectionError, "Failed to connect to Libation companion: #{e.class}"
  end

  def validated_endpoint(path)
    endpoint = OutboundUrlGuard.validate!(
      "#{connection.url}#{path}",
      allow_private: connection.allow_private_network?
    )
    if endpoint.scheme == "http" && !private_address?(endpoint.ipaddr)
      raise ConnectionError, "HTTPS is required for a companion outside the private network"
    end

    endpoint
  end

  def private_address?(value)
    address = IPAddr.new(value)
    OutboundUrlGuard::PRIVATE_RANGES.any? { |range| range.include?(address) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def bearer_token
    return token_from_file if token_file_managed?

    connection.bridge_token.presence || raise(NotConfiguredError, "Libation companion token is not configured")
  end

  def token_from_file
    path = ENV[TOKEN_FILE_ENV].presence
    raise NotConfiguredError, "Libation companion token is not configured" if path.blank?

    token = File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
      stat = file.stat
      unless stat.file? && stat.size <= MAX_TOKEN_BYTES
        raise NotConfiguredError, "Libation companion token file is invalid"
      end

      file.read(MAX_TOKEN_BYTES + 1).to_s.strip
    end
    raise NotConfiguredError, "Libation companion token file is empty" if token.blank?

    token
  rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ELOOP, Errno::ENXIO, Errno::ENODEV
    raise NotConfiguredError, "Libation companion token file cannot be read"
  end

  def read_capped_body(response)
    declared_length = response["Content-Length"].presence&.to_i
    if declared_length && declared_length > MAX_RESPONSE_BYTES
      raise ResponseError, "Libation companion response exceeds #{MAX_RESPONSE_BYTES / 1.megabyte} MB limit"
    end

    body = +""
    response.read_body do |chunk|
      body << chunk
      if body.bytesize > MAX_RESPONSE_BYTES
        raise ResponseError, "Libation companion response exceeds #{MAX_RESPONSE_BYTES / 1.megabyte} MB limit"
      end
    end
    body
  end

  def parse_json(body)
    return {} if body.blank?

    parsed = JSON.parse(body)
    return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)

    raise ResponseError, "Libation companion returned an invalid JSON document"
  rescue JSON::ParserError
    raise ResponseError, "Libation companion returned invalid JSON"
  end

  def extract_array(payload, key, fallback_key: nil)
    entries = if payload.is_a?(Array)
      payload
    elsif payload.is_a?(Hash)
      payload[key] || (fallback_key && payload[fallback_key])
    end

    raise ResponseError, "Libation companion returned an invalid list" unless entries.is_a?(Array)

    entries
  end

  def parse_library_entry(entry)
    unless entry.is_a?(Hash)
      raise ResponseError, "Libation companion returned an invalid library title"
    end

    external_id = entry["asin"].presence || entry["externalId"].presence || entry["id"].presence
    external_id = required_bounded_string(external_id, "Audible ASIN", MAX_ASIN_BYTES)
    unless external_id.match?(ASIN_PATTERN)
      raise ResponseError, "Libation companion returned an invalid Audible ASIN"
    end
    external_id = external_id.upcase
    title = required_bounded_string(entry["title"], "library title", MAX_TITLE_BYTES)

    LibraryEntry.new(
      external_id: external_id,
      media_type: normalize_media_type(entry["mediaType"] || entry["contentType"]),
      title: title,
      subtitle: optional_bounded_string(entry["subtitle"], "library subtitle", MAX_SUBTITLE_BYTES),
      authors: normalize_names(entry["authors"] || entry["author"], label: "author"),
      narrators: normalize_names(entry["narrators"] || entry["narrator"], label: "narrator"),
      cover_url: optional_bounded_string(entry["coverUrl"], "cover URL", MAX_COVER_URL_BYTES),
      language: optional_bounded_string(entry["language"], "language", MAX_LANGUAGE_BYTES),
      duration_seconds: duration_seconds(entry),
      ownership_type: normalize_ownership(entry),
      purchased_at: parse_time(entry["purchasedAt"] || entry["purchaseDate"] || entry["dateAdded"]),
      active: entry.key?("active") ?
        strict_boolean(entry["active"], "active state", default: true) :
        !strict_boolean(entry["absentFromLastScan"], "absence state", default: false),
      downloaded: downloaded_entry?(entry),
      file_path: optional_bounded_string(
        entry["filePath"].presence || entry["artifactPath"].presence || entry["outputPath"].presence,
        "artifact path",
        MAX_FILE_PATH_BYTES
      ),
      payload: safe_library_metadata(entry)
    )
  end

  def parse_job(payload)
    unless payload.is_a?(Hash)
      raise ResponseError, "Libation companion returned an invalid job"
    end

    job_payload = payload["job"].is_a?(Hash) ? payload["job"] : payload
    id = job_payload["id"].presence || job_payload["jobId"].presence
    status = normalize_job_status(job_payload["status"])
    id = id.to_s
    unless id.match?(JOB_ID_PATTERN) && status.present?
      raise ResponseError, "Libation companion returned an invalid job"
    end

    result = job_payload["result"].is_a?(Hash) ? job_payload["result"] : {}
    artifact_paths = Array(
      job_payload["artifactPaths"] || job_payload["outputPaths"] ||
        result["artifactPaths"] || result["outputPaths"]
    )
    artifact_paths << (job_payload["artifactPath"] || result["artifactPath"])
    artifact_paths = artifact_paths.compact_blank
    unless artifact_paths.length <= MAX_ARTIFACT_PATHS &&
        artifact_paths.all? { |path| path.is_a?(String) && path.bytesize <= MAX_ARTIFACT_PATH_BYTES }
      raise ResponseError, "Libation companion returned invalid artifact paths"
    end

    CompanionJob.new(
      id: id,
      status: status,
      artifact_paths: artifact_paths.uniq,
      error: optional_bounded_string(
        job_payload["error"] || result["error"] || job_payload["message"],
        "job error",
        MAX_JOB_ERROR_BYTES
      ),
      payload: payload
    )
  end

  def normalize_job_status(value)
    case value.to_s.strip.downcase
    when "queued", "pending", "created"
      "queued"
    when "running", "in_progress", "in-progress", "downloading", "processing"
      "running"
    when "completed", "complete", "succeeded", "success"
      "completed"
    when "failed", "error"
      "failed"
    when "cancelled", "canceled"
      "cancelled"
    end
  end

  def normalize_media_type(value)
    case value.to_s.strip.downcase
    when "ebook", "book"
      "ebook"
    when "supplement", "pdf"
      "supplement"
    else
      "audiobook"
    end
  end

  def normalize_ownership(entry)
    explicit = optional_bounded_string(entry["ownershipType"], "ownership type", 32).to_s.downcase
    return explicit if OwnedLibraryItem::OWNERSHIP_TYPES.include?(explicit)
    subscription_values = entry.values_at("isPlusCatalog", "isAudiblePlus", "subscription")
    purchased_values = entry.values_at("purchased", "isPurchased")
    if subscription_values.compact.any? do |value|
      strict_boolean(value, "subscription ownership", default: false)
    end
      return "subscription"
    end
    if purchased_values.compact.any? do |value|
      strict_boolean(value, "purchased ownership", default: false)
    end
      return "purchased"
    end

    "unknown"
  end

  def normalize_names(value, label:)
    entries = value.nil? ? [] : (value.is_a?(Array) ? value : [ value ])
    if entries.length > MAX_NAME_ENTRIES
      raise ResponseError, "Libation companion returned too many #{label} names"
    end

    entries.filter_map do |entry|
      name = if entry.is_a?(Hash)
        entry["name"] || entry["displayName"]
      elsif entry.is_a?(String)
        entry
      else
        raise ResponseError, "Libation companion returned an invalid #{label} name"
      end
      optional_bounded_string(name, "#{label} name", MAX_NAME_BYTES)
    end.uniq
  end

  def strict_boolean(value, label, default:)
    return default if value.nil?

    case value
    when true, 1, "1", "true", "TRUE", "yes", "YES"
      true
    when false, 0, "0", "false", "FALSE", "no", "NO"
      false
    else
      raise ResponseError, "Libation companion returned an invalid #{label}"
    end
  end

  def integer_or_nil(value)
    Integer(value, exception: false)
  end

  def duration_seconds(entry)
    seconds = integer_or_nil(entry["durationSeconds"])
    if !entry["durationSeconds"].nil? && seconds.nil?
      raise ResponseError, "Libation companion returned an invalid audiobook duration"
    end

    if seconds.nil?
      minutes = integer_or_nil(entry["lengthMinutes"])
      if !entry["lengthMinutes"].nil? && minutes.nil?
        raise ResponseError, "Libation companion returned an invalid audiobook duration"
      end
      seconds = minutes * 60 if minutes
    end
    return if seconds.nil?
    unless seconds.between?(0, MAX_DURATION_SECONDS)
      raise ResponseError, "Libation companion returned an invalid audiobook duration"
    end

    seconds
  end

  def downloaded_entry?(entry)
    explicit = entry["downloaded"]
    explicit = entry["isDownloaded"] if explicit.nil?
    explicit = entry["backedUp"] if explicit.nil?
    return strict_boolean(explicit, "download state", default: false) unless explicit.nil?

    entry["bookStatus"].to_s.casecmp("liberated").zero?
  end

  def parse_time(value)
    return if value.blank?
    unless value.is_a?(String) && value.bytesize <= MAX_TIMESTAMP_BYTES
      raise ResponseError, "Libation companion returned an invalid timestamp"
    end

    Time.zone.parse(value) ||
      raise(ResponseError, "Libation companion returned an invalid timestamp")
  rescue ArgumentError
    raise ResponseError, "Libation companion returned an invalid timestamp"
  end

  def safe_library_metadata(entry)
    entry.slice(*SAFE_LIBRARY_METADATA_KEYS).to_h do |key, value|
      [ key, safe_metadata_value(value, key) ]
    end
  end

  def safe_metadata_value(value, key)
    case value
    when nil, true, false, Integer, Float
      value
    when String
      if value.bytesize > MAX_METADATA_STRING_BYTES
        raise ResponseError, "Libation companion returned oversized #{key} metadata"
      end
      value
    when Array
      if value.length > MAX_NAME_ENTRIES || !value.all? { |item| item.is_a?(String) }
        raise ResponseError, "Libation companion returned invalid #{key} metadata"
      end
      value.each do |item|
        if item.bytesize > MAX_METADATA_STRING_BYTES
          raise ResponseError, "Libation companion returned oversized #{key} metadata"
        end
      end
      value
    else
      raise ResponseError, "Libation companion returned invalid #{key} metadata"
    end
  end

  def required_bounded_string(value, label, maximum_bytes)
    bounded = optional_bounded_string(value, label, maximum_bytes)
    return bounded if bounded.present?

    raise ResponseError, "Libation companion returned a missing #{label}"
  end

  def optional_bounded_string(value, label, maximum_bytes)
    return if value.nil?
    unless value.is_a?(String)
      raise ResponseError, "Libation companion returned an invalid #{label}"
    end

    bounded = value.strip
    if bounded.bytesize > maximum_bytes
      raise ResponseError, "Libation companion returned an oversized #{label}"
    end
    bounded.presence
  end

  def validate_auth_url!(value, label:)
    if !value.is_a?(String) || value.bytesize > 16.kilobytes
      raise ResponseError, "Libation companion returned an unsafe Audible #{label} URL"
    end

    uri = URI.parse(value.to_s)
    host = uri.host.to_s.downcase
    valid_host = AUTH_HOST_SUFFIXES.any? do |suffix|
      host == suffix || host.end_with?(".#{suffix}")
    end
    return if uri.scheme == "https" && valid_host && uri.userinfo.blank?

    raise ResponseError, "Libation companion returned an unsafe Audible #{label} URL"
  rescue URI::InvalidURIError
    raise ResponseError, "Libation companion returned an unsafe Audible #{label} URL"
  end
end
