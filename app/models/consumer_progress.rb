# frozen_string_literal: true

class ConsumerProgress < ApplicationRecord
  belongs_to :user
  belongs_to :book

  # observed_at is the device-reported activity time, or nil when unknown.
  # updated_at is when the server accepted the write.
  def representation
    { asset_id: asset_id, locator: locator, position_seconds: position_seconds,
      version: version, observed_at: observed_at&.utc&.iso8601(3), updated_at: updated_at.utc.iso8601(3),
      client_mutation_id: client_mutation_id }
  end
end
