# frozen_string_literal: true

module Integrations
  module Telegram
    class SearchResultCache
      CACHE_PREFIX = "telegram_search_result"
      TTL = 1.hour

      class << self
        def store(result)
          token = SecureRandom.hex(16)
          Rails.cache.write(cache_key(token), selection_for(result), expires_in: TTL)
          token
        end

        def fetch(token)
          value = Rails.cache.read(cache_key(token))
          return nil if value.blank?

          value.symbolize_keys
        end

        def callback_data(token, book_type)
          data = "req|#{token}|#{book_type}"
          raise ArgumentError, "Telegram callback_data exceeds 64 bytes" if data.bytesize > 64

          data
        end

        def content_kind_for(result)
          ContentKinds.resolve(
            result.respond_to?(:content_kind) ? result.content_kind : nil,
            source_work_ids: source_work_ids_for(result),
            default: ContentKinds::BOOK
          )
        end

        private

        def cache_key(token)
          "#{CACHE_PREFIX}:#{token}"
        end

        def selection_for(result)
          {
            work_id: result.work_id,
            source_work_ids: source_work_ids_for(result),
            metadata_attrs: {
              title: result.title,
              author: result.author,
              year: result_year(result),
              content_kind: content_kind_for(result)
            }.compact
          }
        end

        def source_work_ids_for(result)
          source_work_ids = if result.respond_to?(:sources)
            Array(result.sources).filter_map { |source| source[:work_id] }.uniq
          else
            [ result.work_id ]
          end

          source_work_ids.presence || [ result.work_id ].compact
        end

        def result_year(result)
          if result.respond_to?(:year)
            result.year
          elsif result.respond_to?(:first_publish_year)
            result.first_publish_year
          end
        end
      end
    end
  end
end
