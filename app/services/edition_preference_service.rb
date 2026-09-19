# frozen_string_literal: true

# Resolve an automatic collection-acquisition tie using publication metadata for
# the offered copy. Upload timestamps and years parsed from release names are
# deliberately not edition evidence.
class EditionPreferenceService
  def self.call(request:, candidates:)
    new(request, candidates).call
  end

  def initialize(request, candidates)
    @request = request
    @candidates = candidates
  end

  def call
    best = @candidates.first
    return best unless best && @request.request_scope == "collection"
    return best unless @request.book.book_type.in?(%w[ebook audiobook])

    best_year = edition_year(best)
    return best unless best_year

    quality = quality_key(best)
    @candidates.drop(1).each do |candidate|
      next unless quality_key(candidate) == quality

      year = edition_year(candidate)
      next unless year && year > best_year

      best = candidate
      best_year = year
    end

    best
  end

  private

  def edition_year(result)
    return unless result.source.in?([ SearchResult::SOURCE_ZLIBRARY, SearchResult::SOURCE_CUSTOM ])
    return unless result.provider_payload.is_a?(Hash)

    value = result.provider_payload["edition_year"]
    return unless value.is_a?(Integer) || value.is_a?(String)
    return unless value.to_s.match?(/\A[1-9]\d{3}\z/)

    year = value.to_i
    year if year <= Date.current.year
  end

  def quality_key(result)
    # Keep every scored identity, format and quality component: equal totals can
    # conceal a poorer title match offset by another factor or score clamping.
    [ result.download_type, result.confidence_score, result.detected_language, result.score_breakdown ]
  end
end
