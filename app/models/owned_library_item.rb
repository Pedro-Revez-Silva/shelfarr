# frozen_string_literal: true

require "uri"

class OwnedLibraryItem < ApplicationRecord
  MEDIA_TYPES = %w[audiobook ebook supplement].freeze
  OWNERSHIP_TYPES = %w[purchased subscription unknown].freeze
  ALLOWED_COVER_HOSTS = %w[
    m.media-amazon.com
    images-na.ssl-images-amazon.com
    images-eu.ssl-images-amazon.com
    images-fe.ssl-images-amazon.com
  ].freeze

  belongs_to :owned_library_connection
  belongs_to :book, optional: true

  has_many :owned_media_imports, dependent: :destroy

  before_destroy :prevent_destroy_during_owned_media_acquisition, prepend: true

  validates :external_id, presence: true,
    uniqueness: { scope: :owned_library_connection_id }
  validates :title, presence: true
  validates :media_type, inclusion: { in: MEDIA_TYPES }
  validates :ownership_type, inclusion: { in: OWNERSHIP_TYPES }
  validates :duration_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    allow_nil: true

  scope :active, -> { where(active: true) }
  scope :purchased, -> { where(ownership_type: "purchased") }
  scope :subscription, -> { where(ownership_type: "subscription") }
  scope :backed_up, -> { where(downloaded: true) }
  scope :not_backed_up, -> { where(downloaded: false) }
  scope :alphabetical, -> { order(title: :asc, external_id: :asc) }
  scope :visible_in_library, -> {
    active
      .purchased
      .where(media_type: "audiobook")
      .joins(:owned_library_connection)
      .merge(OwnedLibraryConnection.enabled)
      .left_outer_joins(:book)
      .where("books.id IS NULL OR books.file_path IS NULL OR TRIM(books.file_path) = ''")
  }

  def self.preload_latest_imports(items)
    records = Array(items)
    latest_imports = OwnedMediaImport.latest_by_owned_library_item_id(records.map(&:id))
    records.each { |item| item.preload_latest_import(latest_imports[item.id]) }
    records
  end

  def purchased?
    ownership_type == "purchased"
  end

  def subscription?
    ownership_type == "subscription"
  end

  def backed_up?
    downloaded?
  end

  def author
    Array(authors).compact_blank.join(", ").presence
  end

  def narrator
    Array(narrators).compact_blank.join(", ").presence
  end

  def display_title
    subtitle.present? ? "#{title}: #{subtitle}" : title
  end

  def cover_image_url
    value = cover_url.to_s.strip
    return if value.blank?

    uri = URI.parse(value)
    if uri.scheme == "https" && uri.userinfo.blank? && uri.port == 443 &&
        ALLOWED_COVER_HOSTS.include?(uri.host.to_s.downcase) &&
        uri.path.start_with?("/images/")
      return value
    end

    if value.match?(/\A[A-Za-z0-9_+\-]{6,128}\z/)
      "https://m.media-amazon.com/images/I/#{value}._SL500_.jpg"
    end
  rescue URI::InvalidURIError
    nil
  end

  def latest_import
    return @preloaded_latest_import if instance_variable_defined?(:@preloaded_latest_import)

    if owned_media_imports.loaded?
      owned_media_imports.max_by { |media_import| [ media_import.created_at, media_import.id ] }
    else
      owned_media_imports.order(created_at: :desc, id: :desc).first
    end
  end

  def preload_latest_import(media_import)
    @preloaded_latest_import = media_import
  end

  private

  def prevent_destroy_during_owned_media_acquisition
    return unless owned_media_imports.cancellation_blocking.exists?

    errors.add(:base, "This Audible title has queued or recoverable backup work and cannot be deleted safely")
    throw :abort
  end
end
