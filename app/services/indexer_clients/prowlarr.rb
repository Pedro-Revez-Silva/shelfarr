# frozen_string_literal: true

module IndexerClients
  class Prowlarr < Base
    Result = IndexerClients::Result

    # Prowlarr's own default when a definition carries no priority, so
    # de-duplication always has something to order by.
    DEFAULT_INDEXER_PRIORITY = 25

    class << self
      def search(query, categories: nil, book_type: nil, limit: 100, title: nil, author: nil)
        ensure_configured!

        cats = categories || categories_for_type(book_type)

        if search_type_for(title: title, author: author) == "search"
          items = execute_search(query, type: "search", categories: cats, limit: limit, indexer_ids: filtered_indexer_ids)
          return items.map { |item| parse_result(item) }
        end

        # Resolve the configured tag scope once and carry it through. Reading it
        # a second time while planning lets a transient /api/v1/tag failure read
        # as "no tags configured" and widen the search past the user's scope.
        tags = indexer_filter_tags
        scoped = scoped_indexers(tags: tags)
        plans = book_search_plans(query, title: title, author: author, tags: tags, indexers: scoped)
        items = execute_book_search_plans(plans, categories: cats, limit: limit)

        deduplicate_by_guid(items, indexer_priorities(scoped)).map { |item| parse_result(item) }
      end

      def indexers
        ensure_configured!

        response = request(idempotent: true) { connection.get("api/v1/indexer") }
        handle_response(response) { |data| Array(data) }
      end

      # Indexers Prowlarr would search on our behalf: every configured indexer,
      # or only the tagged subset when prowlarr_tags is set. Returns nil when
      # Prowlarr's indexer list cannot be read.
      def scoped_indexers(tags: indexer_filter_tags)
        normalized_tags = tags.map(&:to_s).map(&:downcase)
        all = indexers
        return all if normalized_tags.empty?

        all.select { |indexer| (normalized_indexer_tags(indexer["tags"]) & normalized_tags).any? }
      rescue IndexerClients::Base::Error => e
        Rails.logger.warn "[IndexerClients::Prowlarr] Failed to fetch indexers: #{e.message}"
        nil
      end

      def filtered_indexer_ids
        tags = indexer_filter_tags
        return nil if tags.empty?

        scoped_indexers(tags: tags)&.map { |indexer| indexer["id"] }
      end

      def configured_tags
        tags_setting = SettingsService.get(:prowlarr_tags).to_s.strip
        return [] if tags_setting.blank?

        tags_setting.split(",").map { |tag| tag.strip.to_i }.reject(&:zero?)
      end

      def configured_tag_names
        tags_setting = SettingsService.get(:prowlarr_tags).to_s.strip
        return [] if tags_setting.blank?

        tags_setting.split(",").map(&:strip).reject do |tag|
          tag.blank? || tag.match?(/\A\d+\z/)
        end
      end

      def indexer_filter_tags
        configured_tags.concat(configured_tag_ids_for_names(configured_tag_names)).uniq
      end

      def configured?
        SettingsService.prowlarr_configured?
      end

      def test_connection
        ensure_configured!

        response = request(idempotent: true) { connection.get("api/v1/indexer") }
        response.status == 200
      rescue IndexerClients::Base::Error
        false
      end

      def display_name
        "Prowlarr"
      end

      private

      def configured_tag_ids_for_names(tag_names)
        return [] if tag_names.empty?

        response = request(idempotent: true) { connection.get("api/v1/tag") }
        handle_response(response) do |tags|
          tag_lookup = {}

          Array(tags).each do |tag|
            next unless tag.is_a?(Hash)

            label = tag["label"] || tag["name"] || tag["tag"]
            tag_id = tag["id"] || tag["tagId"]
            next if label.blank? || tag_id.blank?

            tag_lookup[label.to_s.strip.downcase] = tag_id.to_i
          end

          tag_names.filter_map { |name| tag_lookup[name.to_s.downcase] }
        end
      rescue IndexerClients::Base::Error => e
        Rails.logger.warn "[IndexerClients::Prowlarr] Failed to resolve tag names for filtering: #{e.message}"
        []
      end

      def normalized_indexer_tags(tags)
        tags.to_a.flat_map do |tag|
          case tag
          when Hash
            [ tag["id"], tag["label"], tag["name"] ]
          else
            tag
          end
        end.compact.map(&:to_s).map(&:downcase)
      end

      def connection
        @connection ||= Faraday.new(url: base_url) do |f|
          f.options.params_encoder = Faraday::FlatParamsEncoder
          f.request :url_encoded
          f.response :json, parser_options: { symbolize_names: false }
          f.adapter Faraday.default_adapter
          f.headers["X-Api-Key"] = api_key
          f.options.timeout = 30
          f.options.open_timeout = 10
        end
      end

      def base_url
        normalize_base_url(SettingsService.get(:prowlarr_url))
      end

      def api_key
        SettingsService.get(:prowlarr_api_key)
      end

      def handle_response(response)
        case response.status
        when 200
          yield response.body
        when 401, 403
          raise Base::AuthenticationError, "Invalid Prowlarr API key"
        when 404
          raise Base::Error, "Prowlarr endpoint not found"
        else
          raise Base::Error, "Prowlarr API error: #{response.status}"
        end
      end

      def parse_result(item)
        Result.new(
          guid: item["guid"],
          title: item["title"],
          indexer: item["indexer"],
          size_bytes: item["size"],
          seeders: item["seeders"],
          leechers: item["leechers"],
          download_url: extract_download_url(item),
          magnet_url: extract_magnet_url(item),
          info_url: item["infoUrl"],
          published_at: parse_date(item["publishDate"]),
          category_ids: extract_category_ids(item)
        )
      end

      def extract_category_ids(item)
        Array(item["categories"]).filter_map do |category|
          value = category.is_a?(Hash) ? category["id"] || category["Id"] || category["ID"] : category
          Integer(value, exception: false)
        end.uniq
      end

      def extract_download_url(item)
        url = item["downloadUrl"]
        return nil if url.blank? || url.start_with?("magnet:")

        Rails.logger.debug "[IndexerClients::Prowlarr] Received download URL from indexer '#{item['indexer']}' (#{url.length} chars): #{UrlRedactor.redact(url).truncate(100)}"
        url
      end

      def extract_magnet_url(item)
        magnet = item["magnetUrl"]
        return magnet if magnet.present?

        url = item["downloadUrl"]
        url if url.present? && url.start_with?("magnet:")
      end

      def parse_date(date_string)
        return nil if date_string.blank?

        Time.parse(date_string)
      rescue ArgumentError
        nil
      end

      def execute_search(query, type:, categories:, limit:, indexer_ids:)
        params = { query: query, type: type, limit: limit }
        params[:categories] = Array(categories) if categories.present?
        params[:indexerIds] = indexer_ids if indexer_ids.present?

        response = request(idempotent: true) { connection.get("api/v1/search", params) }

        handle_response(response) { |data| Array(data) }
      end

      # A plan can name indexers Prowlarr will not search: it drops disabled
      # definitions and indexers it has temporarily blocked after repeated
      # failures from an explicit indexerIds selection, then fails the whole
      # search ("Search failed due to all selected indexers being unavailable",
      # HTTP 400) when nothing is left. That must not throw away what the other
      # plan already returned, so an error is only propagated when every plan
      # fails.
      def execute_book_search_plans(plans, categories:, limit:)
        items = []
        errors = []

        plans.each do |plan|
          items.concat(
            execute_search(plan[:query], type: "book", categories: categories, limit: limit, indexer_ids: plan[:indexer_ids])
          )
        rescue IndexerClients::Base::Error => e
          selection = plan[:indexer_ids] ? plan[:indexer_ids].join(", ") : "all indexers"
          Rails.logger.warn "[IndexerClients::Prowlarr] Book search plan failed (#{selection}): #{e.message}"
          errors << e
        end

        raise errors.first if errors.any? && errors.size == plans.size

        items
      end

      # Prowlarr de-duplicates by GUID within a single search and keeps the copy
      # from the highest-priority indexer (DeDupeReleases orders by ascending
      # IndexerPriority). Splitting the search across plans moves that job here,
      # since the same release can legitimately come back from both plans.
      def deduplicate_by_guid(items, priorities)
        best = {}

        items.each do |item|
          # Nothing to de-duplicate a GUID-less result against; key it on
          # identity so it is kept rather than merged with another.
          key = item["guid"].presence || item.object_id
          incumbent = best[key]
          next if incumbent && indexer_priority(incumbent, priorities) <= indexer_priority(item, priorities)

          best[key] = item
        end

        best.values
      end

      def indexer_priorities(indexers)
        Array(indexers).each_with_object({}) do |indexer, priorities|
          next unless indexer.is_a?(Hash)

          id = indexer["id"]
          priority = Integer(indexer["priority"], exception: false)
          priorities[id] = priority if id.present? && priority
        end
      end

      def indexer_priority(item, priorities)
        priorities.fetch(item["indexerId"], DEFAULT_INDEXER_PRIORITY)
      end

      # Prowlarr does not degrade a book search gracefully: when the query
      # carries a {title:} or {author:} token that an indexer does not
      # advertise in its bookSearchParams, that indexer is skipped outright
      # ("Book search skipped due to unsupported capabilities used") and
      # contributes nothing, rather than being queried on the free text.
      # Most torrent trackers advertise `q` only, so a structured query
      # retrieves literally zero results there while looking healthy.
      #
      # Group the indexers we are about to search by what they can actually
      # accept and give each group the richest query it supports. A token is
      # only ever emitted when the indexer is known to support it; everything
      # else falls back to free text, which every indexer accepts.
      def book_search_plans(query, title:, author:, tags: indexer_filter_tags, indexers: scoped_indexers(tags: tags))
        free_text_query = build_free_text_query(query, title: title, author: author)

        # Indexer list unavailable, or nothing matched the configured tags: keep
        # letting Prowlarr pick the indexers, with the query shape none of them
        # can reject.
        return [ search_plan(free_text_query, nil) ] if indexers.blank?

        available = indexers.select { |indexer| searchable?(indexer) }

        # Every indexer in scope is disabled or blocked. Prowlarr would fail any
        # explicit selection built from them, and there is nothing else to ask.
        return [] if available.empty?

        structured, free_text = available.partition do |indexer|
          supports_structured_book_search?(indexer, title: title, author: author)
        end

        plans = []
        plans << search_plan(build_query(query, title: title, author: author), indexer_ids(structured)) if structured.any?
        plans << search_plan(free_text_query, indexer_ids(free_text)) if free_text.any?

        # One plan covers every indexer Prowlarr would have searched anyway, so
        # drop the selection and leave the choice to Prowlarr exactly as before
        # this split existed. An indexer blocked since the list was read then
        # costs nothing. Only safe without a tag scope: with one, "every indexer
        # Prowlarr would search" is the whole enabled set, not the tagged subset.
        plans.first[:indexer_ids] = nil if plans.one? && tags.empty?

        plans
      end

      # Prowlarr searches neither a disabled indexer nor one it has temporarily
      # blocked after repeated failures, and rejects a selection containing only
      # those, so they must not shape a plan.
      def searchable?(indexer)
        return false unless indexer.is_a?(Hash)
        return false if indexer["enable"] == false

        disabled_till = indexer.dig("status", "disabledTill")
        return true if disabled_till.blank?

        Time.parse(disabled_till.to_s) <= Time.current
      rescue ArgumentError
        true
      end

      def indexer_ids(indexers)
        indexers.filter_map { |indexer| indexer["id"] }.presence
      end

      def search_plan(query, indexer_ids)
        { query: query, indexer_ids: indexer_ids }
      end

      def supports_structured_book_search?(indexer, title:, author:)
        params = book_search_params(indexer)
        return false if params.nil?
        return false if sanitized_book_value(title).present? && !params.include?("title")
        return false if sanitized_book_value(author).present? && !params.include?("author")

        true
      end

      def book_search_params(indexer)
        return nil unless indexer.is_a?(Hash)

        capabilities = indexer["capabilities"]
        return nil unless capabilities.is_a?(Hash)

        params = capabilities["bookSearchParams"]
        return nil unless params.is_a?(Array)

        params.map { |param| param.to_s.downcase }
      end

      def search_type_for(title:, author:)
        sanitized_book_value(title).present? || sanitized_book_value(author).present? ? "book" : "search"
      end

      def build_query(query, title:, author:)
        return query if search_type_for(title: title, author: author) == "search"

        parts = []
        sanitized_title = sanitized_book_value(title)
        sanitized_author = sanitized_book_value(author)

        parts << "{title:#{sanitized_title}}" if sanitized_title.present?
        parts << "{author:#{sanitized_author}}" if sanitized_author.present?
        parts << query if query.present?
        parts.join(" ")
      end

      def build_free_text_query(query, title:, author:)
        [ sanitized_book_value(title), sanitized_book_value(author), query ]
          .compact_blank
          .join(" ")
          .squish
      end

      def sanitized_book_value(value)
        value.to_s.tr("{}", "  ").squish.presence
      end
    end
  end
end
