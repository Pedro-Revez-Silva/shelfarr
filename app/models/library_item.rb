# frozen_string_literal: true

class LibraryItem < ApplicationRecord
  MAX_DISPLAY_TEXT_CHARACTERS = 500
  MAX_DISPLAY_TEXT_BYTES = MAX_DISPLAY_TEXT_CHARACTERS * 4
  BIDI_CONTROL_PATTERN = /[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/

  validates :library_platform, presence: true, inclusion: { in: SettingsService::LIBRARY_PLATFORMS }
  validates :library_id, presence: true
  validates :audiobookshelf_id, presence: true
  validates :library_id, uniqueness: { scope: [ :library_platform, :audiobookshelf_id ] }

  scope :by_synced_at_desc, -> { order(synced_at: :desc, title: :asc) }
  scope :for_platform, ->(platform) { where(library_platform: platform) }
  scope :for_active_platform, -> { for_platform(SettingsService.active_library_platform) }
  scope :for_libraries, ->(ids) { where(library_id: ids) }
  scope :available_for_matching, -> { for_active_platform.where.not(missing: true) }

  def library_url
    LibraryPlatformClient.item_url(self)
  end

  def audiobookshelf_url
    library_url
  end

  def display_title
    sanitized_text([ sanitized_text(title).presence, sanitized_text(subtitle).presence ].compact.join(": "))
  end

  def display_author
    sanitized_text(author)
  end

  def series_label
    series_text = sanitized_text(series)
    return nil if series_text.blank?

    position_text = sanitized_text(series_position)
    return series_text if position_text.blank?

    sanitized_text("#{series_text} ##{position_text}")
  end

  def detail_badges
    narrator_text = sanitized_text(narrator)
    publisher_text = sanitized_text(publisher)
    language_text = sanitized_text(language)

    [
      published_year,
      series_label,
      narrator_text.present? ? sanitized_text("Narrated by #{narrator_text}") : nil,
      publisher_text.presence,
      language_text.present? ? sanitized_text(language_text.upcase) : nil
    ].compact
  end

  def identifier_label
    isbn_text = sanitized_text(isbn)
    return sanitized_text("ISBN #{isbn_text}") if isbn_text.present?

    asin_text = sanitized_text(asin)
    return sanitized_text("ASIN #{asin_text}") if asin_text.present?

    nil
  end

  def sync_stale?(threshold:)
    synced_at.blank? || synced_at < threshold
  end

  def effective_synced_at
    synced_at if synced_at.present? && synced_at <= Time.current
  end

  private

  def sanitized_text(value)
    raw = value.to_s
    text = raw.byteslice(0, MAX_DISPLAY_TEXT_BYTES).to_s
              .encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
              .gsub(BIDI_CONTROL_PATTERN, "")
              .gsub(/[[:cntrl:]]/, " ")
              .gsub(/\s+/, " ")
              .strip
    return text if text.length <= MAX_DISPLAY_TEXT_CHARACTERS && raw.bytesize <= MAX_DISPLAY_TEXT_BYTES

    "#{text.slice(0, MAX_DISPLAY_TEXT_CHARACTERS - 3)}..."
  end
end
