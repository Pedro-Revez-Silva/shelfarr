# frozen_string_literal: true

class KoboDevice < ApplicationRecord
  # The stock Store endpoint, shown so a lost configuration backup can be
  # restored. Shelfarr cannot read the reader's own configuration file.
  STORE_ENDPOINT = Kobo::StoreProxy::ORIGIN
  STORE_STATUSES = %w[ok unavailable rejected authorization].freeze

  belongs_to :user
  has_many :kobo_deliveries, dependent: :destroy
  has_many :kobo_local_entitlements, dependent: :delete_all
  has_many :kobo_tags, dependent: :delete_all

  validates :name, presence: true, length: { maximum: 80 }
  validates :token_digest, presence: true, uniqueness: true
  validates :store_status, inclusion: { in: STORE_STATUSES }, allow_nil: true
  validate :valid_base_url
  # The reader's own Kobo sign-in passes through Shelfarr in this mode.
  validate :coexistence_requires_https

  normalizes :name, with: ->(value) { value.strip }
  normalizes :base_url, with: ->(value) { value.strip.sub(%r{/+\z}, "") }
  after_update :invalidate_outbound_places, if: :saved_change_to_receive_progress?

  def self.issue(user:, **attributes)
    token = SecureRandom.hex(32)
    [ user.kobo_devices.new(**attributes, token_digest: Digest::SHA256.hexdigest(token)), token ]
  end

  def self.delivered_edition(publication)
    publication && [ publication["fingerprint"], publication.dig("kepub", "sha256") ]
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
    publish!({ book: book }, KoboPublication.new(book).snapshot)
  end

  # Queues a household member's (or the owner's own) private DRM-free copy.
  # Its entitlement ID is a new random UUID, so it can never collide with a
  # Store entitlement or a library delivery on this reader. The caller has
  # already checked the grant; it is checked again whenever the reader asks.
  def send_account_book!(cached, share:)
    book = cached.kobo_account_book
    raise KoboPublication::Unavailable, "This copy is not ready" unless cached.ready?

    filename = "#{book.title.gsub(/[^[:alnum:] ._-]+/, ' ').squish.first(120).presence || 'Kobo book'}.epub"
    publication = {
      "fingerprint" => KoboDelivery.private_fingerprint(cached), "size" => cached.size_bytes,
      "filename" => filename, "format" => "EPUB", "epub_version" => cached.epub_version,
      "title" => book.title, "author" => book.author.to_s, "description" => "", "source" => "kobo_account"
    }
    publish!({ kobo_account_book: book }, publication, kobo_account_share: share, kobo_account_book_file: cached)
  end

  def change_tags!
    with_lock do
      increment(:sync_revision)
      save!
      yield kobo_tags, sync_revision
    end
  end

  private

  # A sync while receiving is off may advance past a withheld state revision.
  # Re-evaluate on the next opt-in so that cursor can receive the current place.
  # Keep the actual handoff history: an old adoption echo is still not reading.
  def invalidate_outbound_places
    kobo_deliveries.where.not(progress_outbound: nil).find_each do |delivery|
      delivery.update_columns(progress_outbound: delivery.progress_outbound.except("key"))
    end
  end

  def publish!(identity, publication, **attributes)
    with_lock do
      increment(:sync_revision)
      save!
      delivery = kobo_deliveries.find_or_initialize_by(identity)
      delivery.entitlement_id ||= SecureRandom.uuid
      # A different source generation, or different bytes for the same source
      # (a plain EPUB first sent before Kobo editions, sent again as one), is a
      # different file on the reader.
      changed = self.class.delivered_edition(delivery.publication) != self.class.delivered_edition(publication)
      if changed
        delivery.progress_generation_ambiguous = true if delivery.persisted? && delivery.last_download_at.present?
        delivery.reading_state = nil
        delivery.progress_bridge = nil
        delivery.progress_outbound = nil
      end
      copy_id = publication.dig("kepub", "copy_id")
      raise KoboPublication::Unavailable, "The Kobo edition was removed meanwhile; send the book again" if copy_id && !KoboKepubCopy.exists?(copy_id)

      delivery.update!(revision_id: SecureRandom.uuid, sync_revision: sync_revision, file_sync_revision: sync_revision,
        publication: publication, last_download_at: changed ? nil : delivery.last_download_at, kobo_kepub_copy_id: copy_id, **attributes)
      kobo_local_entitlements.create_or_find_by!(entitlement_id: delivery.entitlement_id)
      delivery
    end
  end

  def coexistence_requires_https
    return unless store_coexistence?

    errors.add(:base_url, "must use HTTPS to keep the Kobo Store on this reader") unless URI.parse(base_url.to_s).scheme == "https"
  rescue URI::InvalidURIError
    nil
  end

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
