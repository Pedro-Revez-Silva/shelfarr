# frozen_string_literal: true

class KoboDevice < ApplicationRecord
  belongs_to :user
  has_many :kobo_deliveries, dependent: :destroy

  validates :name, presence: true, length: { maximum: 80 }
  validates :token_digest, presence: true, uniqueness: true
  validate :valid_base_url

  normalizes :name, with: ->(value) { value.strip }
  normalizes :base_url, with: ->(value) { value.strip.sub(%r{/+\z}, "") }

  def self.issue(user:, **attributes)
    token = SecureRandom.hex(32)
    [ user.kobo_devices.new(**attributes, token_digest: Digest::SHA256.hexdigest(token)), token ]
  end

  def self.authenticate(token)
    return unless token.to_s.match?(/\A[0-9a-f]{64}\z/)

    joins(:user).merge(User.active).find_by(token_digest: Digest::SHA256.hexdigest(token))
  end

  def rotate_token!
    token = SecureRandom.hex(32)
    update!(token_digest: Digest::SHA256.hexdigest(token))
    token
  end

  def endpoint(token)
    "#{base_url}/kobo/#{token}"
  end

  # The counter is advanced in the same transaction as publication. A sync
  # cursor never skips a delivery committed later with an earlier timestamp.
  def send_book!(book)
    publication = KoboPublication.new(book).snapshot
    with_lock do
      increment(:sync_revision)
      save!
      delivery = kobo_deliveries.find_or_initialize_by(book: book)
      delivery.entitlement_id ||= SecureRandom.uuid
      delivery.reading_state = nil if delivery.publication&.fetch("fingerprint") != publication.fetch("fingerprint")
      delivery.update!(revision_id: SecureRandom.uuid, sync_revision: sync_revision,
        publication: publication, last_download_at: nil)
      delivery
    end
  end

  private

  def valid_base_url
    uri = URI.parse(base_url.to_s)
    unless %w[http https].include?(uri.scheme) && uri.host.present? &&
        uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
        !uri.path.match?(%r{[{}\\]|(?:\A|/)\.\.?(/|\z)})
      errors.add(:base_url, "must be an HTTP or HTTPS address without credentials, query, or fragment")
    end
  rescue URI::InvalidURIError
    errors.add(:base_url, "is not a valid address")
  end
end
