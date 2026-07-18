# frozen_string_literal: true

require "uri"

class StoreOffer < ApplicationRecord
  FRESHNESS_TTL = 24.hours
  MAX_FUTURE_QUOTE_SKEW = 5.minutes
  MAX_EXTERNAL_ID_LENGTH = 64
  MAX_TITLE_LENGTH = 500
  MAX_AUTHOR_LENGTH = 300
  MAX_ISBNS = 20
  MAX_DRM_TYPE_LENGTH = 64
  MAX_LOCALIZED_PRICE_LENGTH = 64
  MAX_URL_LENGTH = 2_048
  ALLOWED_FORMATS = %w[epub pdf].freeze
  PROVIDER_NAMES = {
    "ebooks_com" => "eBooks.com"
  }.freeze
  PROVIDER_HOSTS = {
    "ebooks_com" => %w[ebooks.com www.ebooks.com]
  }.freeze

  belongs_to :request

  validates :provider, presence: true, inclusion: { in: PROVIDER_NAMES.keys }
  validates :external_id,
    presence: true,
    length: { maximum: MAX_EXTERNAL_ID_LENGTH },
    format: { with: /\A[A-Za-z0-9_-]+\z/ },
    uniqueness: { scope: [ :request_id, :provider ] }
  validates :title, presence: true, length: { maximum: MAX_TITLE_LENGTH }
  validates :author, length: { maximum: MAX_AUTHOR_LENGTH }, allow_nil: true
  validates :market, presence: true, format: { with: /\A[A-Z]{2}\z/ }
  validates :drm_type, length: { maximum: MAX_DRM_TYPE_LENGTH }, allow_nil: true
  validates :localized_price, length: { maximum: MAX_LOCALIZED_PRICE_LENGTH }, allow_nil: true
  validates :price_amount,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 99_999_999 },
    allow_nil: true
  validates :price_currency, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
  validates :drm_free, inclusion: { in: [ true ] }
  validate :market_is_iso_country
  validate :formats_are_supported
  validate :isbns_are_bounded
  validate :price_fields_are_coherent
  validate :quoted_at_is_not_in_the_future
  validate :text_fields_exclude_controls
  validate :storefront_url_is_safe
  validate :storefront_url_matches_offer
  validate :checkout_url_is_safe
  validate :cover_url_is_safe

  scope :best_first, -> { order(Arel.sql("CASE WHEN localized_price IS NULL OR localized_price = '' THEN 1 ELSE 0 END"), :price_amount, :id) }
  scope :fresh, lambda {
    quoted_or_created = "COALESCE(store_offers.quoted_at, store_offers.created_at)"
    where("#{quoted_or_created} >= ? AND #{quoted_or_created} <= ?", FRESHNESS_TTL.ago, MAX_FUTURE_QUOTE_SKEW.from_now)
  }

  def self.fresh_quote?(quoted_at, now: Time.current)
    quoted_at.present? && quoted_at.between?(now - FRESHNESS_TTL, now + MAX_FUTURE_QUOTE_SKEW)
  rescue ArgumentError, NoMethodError, TypeError
    false
  end

  def provider_name
    PROVIDER_NAMES.fetch(provider, provider.titleize)
  end

  def display_price
    return localized_price if localized_price.present?
    return if price_amount.blank? || price_currency.blank?

    "#{price_currency} #{price_amount.to_s('F')}"
  end

  def format_labels
    Array(formats).map { |value| value.to_s.upcase }.uniq
  end

  def drm_label
    return "DRM-free" if drm_type.blank?

    label = {
      "NoRestriction" => "No restrictions",
      "Watermarked" => "Watermarked"
    }.fetch(drm_type, drm_type.to_s.underscore.humanize)
    "DRM-free (#{label})"
  end

  private

  def storefront_url_is_safe
    validate_external_url(:storefront_url, required: true)
  end

  def checkout_url_is_safe
    validate_external_url(:checkout_url, required: false)
  end

  def storefront_url_matches_offer
    uri = URI.parse(storefront_url.to_s)
    segments = uri.path.to_s.split("/").reject(&:blank?)
    locale = segments.shift
    match = locale&.match(/\A[a-z]{2}-([a-z]{2})\z/i)
    unless match && match[1].upcase == market && segments.first(2) == [ "book", external_id ]
      errors.add(:storefront_url, "must match the quoted buyer market and offer")
    end
  rescue URI::InvalidURIError
    # The generic URL validator provides the actionable error.
  end

  def cover_url_is_safe
    validate_external_url(:cover_url, required: false, allowed_hosts: %w[image.ebooks.com])
  end

  def validate_external_url(attribute, required:, allowed_hosts: nil)
    value = public_send(attribute).to_s.strip
    if value.blank?
      errors.add(attribute, "must be present") if required
      return
    end

    if value.bytesize > MAX_URL_LENGTH || unsupported_characters?(value)
      errors.add(attribute, "must be a safe HTTPS URL")
      return
    end

    uri = URI.parse(value)
    allowed_hosts ||= PROVIDER_HOSTS[provider]
    unless uri.scheme == "https" && uri.host.present? && uri.userinfo.blank? &&
        uri.port == 443 &&
        (allowed_hosts.blank? || allowed_hosts.include?(uri.host.downcase))
      errors.add(attribute, "must be a safe HTTPS URL")
    end
  rescue URI::InvalidURIError
    errors.add(attribute, "must be a safe HTTPS URL")
  end

  def market_is_iso_country
    errors.add(:market, "must be a valid ISO 3166-1 country code") unless EbooksComClient.valid_country_code?(market)
  end

  def formats_are_supported
    unless formats.is_a?(Array) && formats.present? && formats.size <= ALLOWED_FORMATS.size &&
        formats.all? { |format| format.is_a?(String) && ALLOWED_FORMATS.include?(format) } && formats.uniq.size == formats.size
      errors.add(:formats, "must contain unique EPUB or PDF values")
    end
  end

  def isbns_are_bounded
    unless isbns.is_a?(Array) && isbns.size <= MAX_ISBNS && isbns.all? do |isbn|
      isbn.is_a?(String) && isbn.match?(/\A(?:[0-9]{10}|[0-9]{13}|[0-9]{9}X)\z/)
    end
      errors.add(:isbns, "must be a bounded array of normalized ISBN values")
    end
  end

  def price_fields_are_coherent
    amount_present = price_amount.present?
    currency_present = price_currency.present?
    errors.add(:price_currency, "must accompany the numeric price") unless amount_present == currency_present
    if localized_price.present? && !amount_present
      errors.add(:localized_price, "requires a valid numeric price and currency")
    end
  end

  def quoted_at_is_not_in_the_future
    if quoted_at.present? && quoted_at > MAX_FUTURE_QUOTE_SKEW.from_now
      errors.add(:quoted_at, "cannot be in the future")
    end
  end

  def text_fields_exclude_controls
    %i[external_id title author drm_type price_currency localized_price].each do |attribute|
      value = public_send(attribute)
      errors.add(attribute, "contains unsupported control characters") if unsupported_characters?(value.to_s)
    end
  end

  def unsupported_characters?(value)
    !value.valid_encoding? || value.match?(/[\p{Cc}\p{Cf}]/u)
  end
end
