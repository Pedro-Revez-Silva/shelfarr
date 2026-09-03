# frozen_string_literal: true

# Expands metadata titles that contain localized/original aliases separated by
# a spaced slash. The first component remains the preferred provider query,
# while the other component and original text remain available as fallbacks.
class SearchTitleVariantService
  SeparatorPattern = /\s+\/\s+/
  private_constant :SeparatorPattern

  def self.call(title)
    full_title = title.to_s.squish
    return [] if full_title.blank?
    return [ full_title ] unless full_title.match?(SeparatorPattern)

    first, second = full_title.split(SeparatorPattern, 2).map(&:squish)
    [ first, second, full_title ].compact_blank.uniq
  end
end
