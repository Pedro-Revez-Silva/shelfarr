# frozen_string_literal: true

# A book selected for one physical Kobo. It comes either from the shared
# Book library, or from a household member's Kobo account as a private
# DRM-free copy (kobo_account_book). Private deliveries never reference a
# global Book and are served only while Kobo::HouseholdAccess allows them.
class KoboDelivery < ApplicationRecord
  belongs_to :kobo_device
  belongs_to :book, optional: true
  belongs_to :kobo_account_book, optional: true
  belongs_to :kobo_account_share, optional: true
  belongs_to :kobo_account_book_file, optional: true
  belongs_to :kobo_kepub_copy, optional: true

  def private_source?
    kobo_account_book_id.present?
  end

  # Whether the reader may receive this entry now. Library deliveries keep
  # their existing behaviour: a removed source is reported when fetched.
  def deliverable?
    !private_source? || Kobo::HouseholdAccess.delivery_allowed?(self)
  end

  # Whether the reader is offered a Kobo edition prepared from the library EPUB.
  def kepub_copy?
    !private_source? && publication&.fetch("kepub", nil).is_a?(Hash)
  end

  # The bytes the reader downloads. For a prepared Kobo edition, the library
  # file must still be the generation it was prepared from: a replaced source
  # never serves its earlier copy.
  def open_file
    return open_private_file if private_source?
    return open_source unless kepub_copy?

    source = open_source
    Kobo::KepubCache.open(kobo_kepub_copy, sha256: publication.dig("kepub", "sha256"), source: source)
  ensure
    source&.close unless source&.closed?
  end

  # The library file this delivery was published from, pinned to the same
  # generation. Reading places and consumer assets are always compared with it.
  def open_source
    raise KoboPublication::Unavailable, "This book is no longer in the library" unless book

    KoboPublication.new(book).open_file(expected_fingerprint: publication.fetch("fingerprint"))
  end

  # The embedded cover of the file this entry delivers. A prepared Kobo edition
  # keeps the package and images of its source, so the source's cover is read.
  def cover
    file = private_source? ? open_file : open_source
    KoboPublication.new(book).cover(file)
  ensure
    file&.close unless file&.closed?
  end

  private

  def open_private_file
    raise KoboPublication::Unavailable, "Access to this shared book has ended" unless deliverable?

    cached = kobo_account_book_file
    unless publication.fetch("fingerprint") == self.class.private_fingerprint(cached)
      raise KoboPublication::Unavailable, "The shared copy changed; send it again"
    end
    file = Kobo::BookCache.open(cached)
    cached.update_columns(last_used_at: Time.current)
    file
  end

  class << self
    def private_fingerprint(cached)
      "kobo-account:#{cached.id}:#{cached.sha256}"
    end
  end
end
