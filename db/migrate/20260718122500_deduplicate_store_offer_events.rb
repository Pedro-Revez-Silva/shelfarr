# frozen_string_literal: true

class DeduplicateStoreOfferEvents < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_request_events_on_unique_store_offer_state"
  EVENT_TYPE = "store_offers_found"
  EVENT_SOURCE = "store_provider"

  def up
    # Keep the newest state event for each request. Earlier copies contain the
    # same catalog outcome and only make the diagnostics timeline noisy.
    execute <<~SQL.squish
      DELETE FROM request_events
      WHERE event_type = #{connection.quote(EVENT_TYPE)}
        AND source = #{connection.quote(EVENT_SOURCE)}
        AND id NOT IN (
          SELECT MAX(id)
          FROM request_events
          WHERE event_type = #{connection.quote(EVENT_TYPE)}
            AND source = #{connection.quote(EVENT_SOURCE)}
          GROUP BY request_id
        )
    SQL

    add_index :request_events,
      [ :request_id, :event_type, :source ],
      unique: true,
      where: "event_type = 'store_offers_found' AND source = 'store_provider'",
      name: INDEX_NAME
  end

  def down
    remove_index :request_events, name: INDEX_NAME
  end
end
