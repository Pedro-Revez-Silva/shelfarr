# frozen_string_literal: true

# A complete, verified Kobo edition (KEPUB) of one library EPUB generation,
# stored by Kobo::KepubCache. The storage key derives only from the source and
# copy SHA-256 digests, so nothing in a book can choose a path.
class KoboKepubCopy < ApplicationRecord
  STORAGE_KEY = %r{\A[0-9a-f]{2}/[0-9a-f]{64}\.kepub\.epub\z}

  has_many :kobo_deliveries, dependent: :nullify

  validates :converter, :source_sha256, :sha256, :storage_key, presence: true
  validates :storage_key, format: { with: STORAGE_KEY }, uniqueness: true
  validates :size_bytes, :source_size, numericality: { only_integer: true, greater_than: 0 }

  scope :unreferenced, -> { where.not(id: KoboDelivery.where.not(kobo_kepub_copy_id: nil).select(:kobo_kepub_copy_id)) }

  def self.storage_key_for(sha256, source_sha256:)
    # Distinct EPUB containers can produce identical Kobo bytes. Keep their
    # source bindings separate so either original can rebuild its own copy.
    key = Digest::SHA256.hexdigest([ source_sha256, sha256 ].join("\0"))
    "#{key[0, 2]}/#{key}.kepub.epub"
  end
end
