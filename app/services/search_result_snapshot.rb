# frozen_string_literal: true

require "digest"

class SearchResultSnapshot
  TTL = 10.minutes
  PAGE_SIZE = 20
  MAX_PAGES = 10
  MAX_RESULTS = PAGE_SIZE * MAX_PAGES
  MAX_SNAPSHOTS = 3
  MAX_PAYLOAD_BYTES = 2.megabytes
  COLLECTION_OVERHEAD_BYTES = 32.kilobytes
  MAX_SNAPSHOT_BYTES = (MAX_PAYLOAD_BYTES - COLLECTION_OVERHEAD_BYTES) / MAX_SNAPSHOTS
  MAX_QUERY_BYTES = 500
  MAX_IDENTITY_BYTES = 512
  MAX_TEXT_BYTES = 8.kilobytes
  MAX_URL_BYTES = 2.kilobytes
  MAX_SOURCES = 8
  MAX_EDITIONS = 20
  MAX_LIST_VALUES = 20
  MAX_INTEGER = 9_007_199_254_740_991
  MAX_FLOAT = 9_007_199_254_740_991.0
  TOKEN_PATTERN = /\A[A-Za-z0-9_-]{32}\z/

  Snapshot = Data.define(:id, :results, :complete, :failed_providers, :provider_count, :expires_at)

  class << self
    attr_writer :lock_root

    def create(user:, query:, content_kind:, provider_count:)
      binding = normalized_binding(user, query, content_kind)
      return unless binding

      with_user_lock(user) do
        collection = pruned_collection(read_collection(user))
        token = SecureRandom.urlsafe_base64(24)
        collection["snapshots"][token] = binding.merge(
          "token" => token,
          "results" => [],
          "complete" => false,
          "failed_providers" => [],
          "provider_count" => provider_count.to_i.clamp(0, MAX_SOURCES),
          "expires_at" => expires_at
        )
        collection["order"] << token
        trim_collection!(collection)

        token if write_collection(user, collection)
      end
    rescue StandardError => e
      Rails.logger.warn("[SearchResultSnapshot] Cache write failed: #{e.class}")
      nil
    end

    def write(user:, id:, query:, content_kind:, results:, complete:, failed_providers:, provider_count:)
      binding = normalized_binding(user, query, content_kind)
      return false unless binding && TOKEN_PATTERN.match?(id.to_s)

      with_user_lock(user) do
        collection = pruned_collection(read_collection(user))
        payload = collection.dig("snapshots", id)
        next false unless payload_matches?(payload, binding, id)

        payload["complete"] = !!complete
        payload["failed_providers"] = bounded_list(failed_providers, limit: MAX_SOURCES)
        payload["provider_count"] = provider_count.to_i.clamp(0, MAX_SOURCES)
        payload["expires_at"] = expires_at
        payload["results"] = []
        append_bounded_results!(collection, payload, results)

        write_collection(user, collection) && snapshot_from(payload)
      end
    rescue StandardError => e
      Rails.logger.warn("[SearchResultSnapshot] Cache update failed: #{e.class}")
      false
    end

    def fetch(user:, id:, query:, content_kind:)
      binding = normalized_binding(user, query, content_kind)
      return unless binding && TOKEN_PATTERN.match?(id.to_s)

      payload = read_collection(user)&.dig("snapshots", id)
      return unless payload_matches?(payload, binding, id)
      return if expired?(payload)

      snapshot_from(payload)
    rescue StandardError => e
      Rails.logger.warn("[SearchResultSnapshot] Cache read failed: #{e.class}")
      nil
    end

    def normalize_page(value)
      value.to_i.clamp(1, MAX_PAGES)
    end

    def lock_root
      @lock_root || Rails.root.join("tmp", ".shelfarr-search-snapshots")
    end

    def reset_lock_root!
      @lock_root = nil
    end

    private

    def normalized_binding(user, query, content_kind)
      normalized_query = query.to_s.strip
      return if user&.id.blank? || normalized_query.blank? || normalized_query.bytesize > MAX_QUERY_BYTES

      {
        "user_id" => user.id,
        "query" => normalized_query,
        "content_kind" => ContentKinds.normalize(content_kind, default: nil)
      }
    end

    def empty_collection
      { "order" => [], "snapshots" => {} }
    end

    def pruned_collection(value)
      collection = value.is_a?(Hash) ? value : empty_collection
      snapshots = collection["snapshots"].is_a?(Hash) ? collection["snapshots"] : {}
      order = Array(collection["order"]).select { |token| snapshots.key?(token) }
      expired_tokens = order.select { |token| expired?(snapshots[token]) }
      expired_tokens.each { |token| snapshots.delete(token) }

      { "order" => order - expired_tokens, "snapshots" => snapshots.slice(*(order - expired_tokens)) }
    end

    def trim_collection!(collection)
      while collection["order"].size > MAX_SNAPSHOTS || encoded_bytes(collection) > MAX_PAYLOAD_BYTES
        token = collection["order"].shift
        collection["snapshots"].delete(token)
      end
    end

    def append_bounded_results!(collection, payload, results)
      bytes = encoded_bytes(collection)
      snapshot_bytes = JSON.generate(payload).bytesize
      Array(results).first(MAX_RESULTS).each do |result|
        serialized = serialized_result(result)
        next unless serialized

        additional_bytes = JSON.generate(serialized).bytesize
        additional_bytes += 1 if payload["results"].any?
        next if snapshot_bytes + additional_bytes > MAX_SNAPSHOT_BYTES
        next if bytes + additional_bytes > MAX_PAYLOAD_BYTES

        payload["results"] << serialized
        bytes += additional_bytes
        snapshot_bytes += additional_bytes
      end
    end

    def serialized_result(result)
      value = serialize_result(result)
      JSON.generate(value)
      value
    rescue StandardError
      nil
    end

    def payload_matches?(payload, binding, token)
      payload.present? && payload.slice(*binding.keys) == binding && payload["token"] == token
    end

    def snapshot_from(payload)
      Snapshot.new(
        id: payload["token"],
        results: Array(payload["results"]).first(MAX_RESULTS).filter_map { |result| deserialize_result(result) },
        complete: payload["complete"] == true,
        failed_providers: bounded_list(payload["failed_providers"], limit: MAX_SOURCES),
        provider_count: safe_integer(payload["provider_count"])&.clamp(0, MAX_SOURCES).to_i,
        expires_at: safe_integer(payload["expires_at"]).to_i
      )
    end

    def read_collection(user)
      value = Rails.cache.read(cache_key(user))
      return unless value.is_a?(String) && value.bytesize <= MAX_PAYLOAD_BYTES

      JSON.parse(value)
    end

    def write_collection(user, collection)
      value = JSON.generate(collection)
      return false if value.bytesize > MAX_PAYLOAD_BYTES

      Rails.cache.write(cache_key(user), value, expires_in: TTL)
    end

    def encoded_bytes(collection)
      JSON.generate(collection).bytesize
    end

    def with_user_lock(user, &operation)
      root = Pathname(lock_root).expand_path
      FileCopyService.secure_private_directory!(root.to_s, root: root.parent.to_s)
      digest = Digest::SHA256.hexdigest(user.id.to_s)
      FileCopyService.with_private_lock(root.join("#{digest}.lock").to_s, root: root.to_s, &operation)
    end

    def cache_key(user)
      "search_result_snapshot:v3:#{user.id}"
    end

    def expires_at
      TTL.from_now.to_i
    end

    def expired?(payload)
      payload.blank? || safe_integer(payload["expires_at"]).to_i <= Time.current.to_i
    end

    def serialize_result(result)
      {
        "canonical_key" => bounded_text(result.canonical_key),
        "title" => bounded_text(result.title),
        "author" => bounded_text(result.author),
        "year" => scalar(result.year),
        "description" => bounded_text(result.description),
        "cover_url" => bounded_url(result.cover_url),
        "series_name" => bounded_text(result.series_name),
        "series_position" => bounded_text(result.series_position),
        "has_ebook" => scalar(result.has_ebook),
        "has_audiobook" => scalar(result.has_audiobook),
        "sources" => Array(result.sources).first(MAX_SOURCES).filter_map { |source| serialize_source(source) },
        "editions" => Array(result.editions).first(MAX_EDITIONS).filter_map { |edition| serialize_edition(edition) },
        "confidence" => bounded_percentage(result.confidence),
        "content_kind" => bounded_content_kind(result.content_kind),
        "resource_kind" => bounded_text(result.resource_kind),
        "classification_evidence" => bounded_list(result.classification_evidence),
        "classification_confidence" => bounded_percentage(result.classification_confidence),
        "categories" => bounded_list(result.categories),
        "subjects" => bounded_list(result.subjects),
        "collection_source" => bounded_text(result.collection_source),
        "collection_id" => bounded_text(result.collection_id),
        "collection_title" => bounded_text(result.collection_title),
        "issue_number" => bounded_text(result.issue_number),
        "release_date" => bounded_text(result.release_date)
      }
    end

    def deserialize_result(value)
      result = value.to_h.stringify_keys
      MetadataSearch::Candidate.new(
        canonical_key: result["canonical_key"],
        title: result["title"],
        author: result["author"],
        year: result["year"],
        description: result["description"],
        cover_url: result["cover_url"],
        series_name: result["series_name"],
        series_position: result["series_position"],
        has_ebook: result["has_ebook"],
        has_audiobook: result["has_audiobook"],
        sources: Array(result["sources"]).map { |source| source.to_h.symbolize_keys },
        editions: Array(result["editions"]).map { |edition| edition.to_h.symbolize_keys },
        confidence: result["confidence"],
        content_kind: result["content_kind"],
        resource_kind: result["resource_kind"],
        classification_evidence: result["classification_evidence"],
        classification_confidence: result["classification_confidence"],
        categories: result["categories"],
        subjects: result["subjects"],
        collection_source: result["collection_source"],
        collection_id: result["collection_id"],
        collection_title: result["collection_title"],
        issue_number: result["issue_number"],
        release_date: result["release_date"]
      )
    rescue KeyError, TypeError, ArgumentError
      nil
    end

    def serialize_source(value)
      source = value.to_h.symbolize_keys
      {
        source: bounded_identity(source[:source]),
        source_id: bounded_identity(source[:source_id]),
        source_name: bounded_identity(source[:source_name]),
        source_url: bounded_url(source[:source_url]),
        work_id: bounded_identity(source[:work_id])
      }.compact
    rescue StandardError
      nil
    end

    def serialize_edition(value)
      edition = value.to_h.symbolize_keys.slice(
        :source, :source_id, :isbn_10, :isbn_13, :publisher, :year,
        :page_count, :resource_kind
      )
      edition.transform_values { |item| scalar(item, maximum: MAX_IDENTITY_BYTES) }
        .merge(publisher: bounded_text(edition[:publisher]))
        .compact
    rescue StandardError
      nil
    end

    def bounded_list(values, limit: MAX_LIST_VALUES)
      Array(values).first(limit).filter_map { |value| bounded_identity(value) }
    end

    def bounded_percentage(value)
      number = safe_number(value)
      number&.clamp(0, 100)&.to_i || 0
    end

    def bounded_content_kind(value)
      return ContentKinds::BOOK if value.is_a?(Numeric)

      ContentKinds.normalize(value)
    end

    def scalar(value, maximum: MAX_TEXT_BYTES)
      return value if value.nil? || value == true || value == false
      return safe_number(value) if value.is_a?(Numeric)

      bounded_string(value, maximum)
    end

    def safe_number(value)
      return safe_integer(value) if value.instance_of?(Integer)
      return value if value.instance_of?(Float) && value.finite? && value.abs <= MAX_FLOAT

      nil
    end

    def safe_integer(value)
      return unless value.instance_of?(Integer) && value.abs <= MAX_INTEGER

      value
    end

    def bounded_identity(value)
      return scalar(value, maximum: MAX_IDENTITY_BYTES) if value.is_a?(Numeric)

      bounded_string(value, MAX_IDENTITY_BYTES)
    end

    def bounded_text(value)
      return scalar(value) if value.is_a?(Numeric)

      bounded_string(value, MAX_TEXT_BYTES)
    end

    def bounded_url(value)
      return if value.is_a?(Numeric)

      bounded_string(value, MAX_URL_BYTES)
    end

    def bounded_string(value, maximum)
      return if value.nil?

      string = value.to_s
      string.bytesize > maximum ? string.byteslice(0, maximum).scrub : string
    end
  end
end
