# frozen_string_literal: true

class ConsumerProgress < ApplicationRecord
  belongs_to :user
  belongs_to :book

  def representation
    { asset_id: asset_id, locator: locator, position_seconds: position_seconds,
      version: version, updated_at: updated_at.utc.iso8601(3), client_mutation_id: client_mutation_id }
  end
end
