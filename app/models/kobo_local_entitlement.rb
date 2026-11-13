# frozen_string_literal: true

# A device-scoped classification, retained after revocation or disconnection.
# A reader may still upload a bookmark for a private copy it already has; that
# UUID must never become an unknown Store entitlement and leak its bookmark.
class KoboLocalEntitlement < ApplicationRecord
  belongs_to :kobo_device
  validates :entitlement_id, presence: true
end
