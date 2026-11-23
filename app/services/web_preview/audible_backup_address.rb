# frozen_string_literal: true

module WebPreview
  module AudibleBackupAddress
    CARDS = { "overview" => "audible", "connection" => "audible-connection", "automation" => "audible-automation", "catalog" => "audible-catalogue" }.freeze
    LAST_PAGE = 999_999_999

    module_function

    def warm(params)
      tab, query, page = params.values_at(:tab, :q, :page)
      return nil unless [ tab, query, page ].all? { |value| value.nil? || value.is_a?(String) }

      query = query.to_s.strip.first(200)
      page = page.to_i.clamp(1, LAST_PAGE)
      carried = { audible_q: query.presence, audible_page: (page.to_s if page > 1) }.compact
      { card: card(tab, filtered: carried.any?), query: carried.to_query }
    end

    def card(tab, filtered:)
      CARDS.fetch(tab.to_s) { filtered ? CARDS.fetch("catalog") : CARDS.fetch("overview") }
    end
  end
end
