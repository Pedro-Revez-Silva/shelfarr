# frozen_string_literal: true

class RequestMetadataHandoff
  TTL = 1.hour
  MAX_IDENTITY_BYTES = 255
  MAX_SOURCE_WORK_IDS = 8
  TOKEN_PATTERN = /\A[A-Za-z0-9_-]{32}\z/
  IDENTITY_KEYS = %i[
    work_id
    source_work_ids
    content_kind
    request_scope
    collection_source
    collection_id
  ].freeze
  METADATA_KEYS = %i[
    work_id
    source_work_ids
    title
    author
    cover_url
    first_publish_year
    description
    publisher
    content_kind
    issue_number
    release_date
    series
    series_position
    request_scope
    collection_source
    collection_id
    collection_title
  ].freeze

  class << self
    def params_for(user:, metadata:)
      metadata = normalize(metadata)
      token = store(user: user, metadata: metadata)

      compact_identity(metadata).merge(metadata_token: token).compact
    end

    def fetch(user:, token:)
      return {} unless TOKEN_PATTERN.match?(token.to_s)

      normalize(Rails.cache.read(cache_key(user, token)))
    rescue StandardError => e
      Rails.logger.warn("[RequestMetadataHandoff] Cache read failed: #{e.class}")
      {}
    end

    private

    def store(user:, metadata:)
      token = SecureRandom.urlsafe_base64(24)
      written = Rails.cache.write(cache_key(user, token), metadata, expires_in: TTL)
      token if written
    rescue StandardError => e
      Rails.logger.warn("[RequestMetadataHandoff] Cache write failed: #{e.class}")
      nil
    end

    def normalize(metadata)
      metadata.to_h.symbolize_keys.slice(*METADATA_KEYS).compact.tap do |normalized|
        normalized[:source_work_ids] = Array(normalized[:source_work_ids]).compact_blank.uniq if normalized.key?(:source_work_ids)
      end
    end

    def compact_identity(metadata)
      metadata.slice(*IDENTITY_KEYS).transform_values do |value|
        if value.is_a?(Array)
          value.filter_map { |item| bounded_identity(item) }.first(MAX_SOURCE_WORK_IDS)
        else
          bounded_identity(value)
        end
      end.compact
    end

    def bounded_identity(value)
      return value unless value.is_a?(String)
      return value if value.bytesize <= MAX_IDENTITY_BYTES

      nil
    end

    def cache_key(user, token)
      "request_metadata_handoff:v1:#{user&.id || 'anonymous'}:#{token}"
    end
  end
end
