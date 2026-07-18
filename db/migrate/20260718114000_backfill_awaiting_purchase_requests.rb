# frozen_string_literal: true

class BackfillAwaitingPurchaseRequests < ActiveRecord::Migration[8.1]
  AWAITING_PURCHASE_STATUS = 7
  SEARCHING_STATUS = 1
  INFO_LEVEL = 0
  WARN_LEVEL = 1
  LEGACY_EVENT_TYPE = "attention_flagged"
  STORE_OFFER_EVENT_TYPE = "store_offers_found"
  LEGACY_EVENT_SOURCE = "request"
  STORE_OFFER_EVENT_SOURCE = "store_provider"
  LEGACY_DOWN_MESSAGE =
    "DRM-free store offer found. Purchase from the seller and import the file to complete this request."
  STORE_OFFER_MESSAGE = "DRM-free store offers found"
  LEGACY_MESSAGE_PATTERN =
    "% DRM-free store offer% found. Purchase from the seller and have the file imported " \
      "to complete this request, or retry to search again."

  def up
    # The original beta represented an offer-only result as a warning while
    # leaving the request in `searching`. Convert the matching diagnostic at
    # the same time so upgraded installations do not retain a contradictory
    # attention warning for the new neutral state.
    execute <<~SQL.squish
      UPDATE request_events
      SET event_type = #{connection.quote(STORE_OFFER_EVENT_TYPE)},
          source = #{connection.quote(STORE_OFFER_EVENT_SOURCE)},
          level = #{INFO_LEVEL},
          message = #{connection.quote(STORE_OFFER_MESSAGE)},
          updated_at = CURRENT_TIMESTAMP
      WHERE event_type = #{connection.quote(LEGACY_EVENT_TYPE)}
        AND source = #{connection.quote(LEGACY_EVENT_SOURCE)}
        AND message LIKE #{connection.quote(LEGACY_MESSAGE_PATTERN)}
        AND request_id IN (
          SELECT requests.id
          FROM requests
          WHERE requests.status = #{SEARCHING_STATUS}
            AND requests.issue_description LIKE #{connection.quote(LEGACY_MESSAGE_PATTERN)}
            AND EXISTS (
              SELECT 1 FROM store_offers
              WHERE store_offers.request_id = requests.id
            )
        )
    SQL

    execute <<~SQL.squish
      UPDATE requests
      SET status = #{AWAITING_PURCHASE_STATUS},
          attention_needed = 0,
          issue_description = NULL,
          next_retry_at = NULL,
          updated_at = CURRENT_TIMESTAMP
      WHERE status = #{SEARCHING_STATUS}
        AND issue_description LIKE #{connection.quote(LEGACY_MESSAGE_PATTERN)}
        AND EXISTS (
          SELECT 1 FROM store_offers
          WHERE store_offers.request_id = requests.id
        )
    SQL
  end

  def down
    # A rollback can include offer-only requests created after the upgrade.
    # Restore every matching neutral event attached to status 7 before the
    # request rows are made understandable to the older application.
    execute <<~SQL.squish
      UPDATE request_events
      SET event_type = #{connection.quote(LEGACY_EVENT_TYPE)},
          source = #{connection.quote(LEGACY_EVENT_SOURCE)},
          level = #{WARN_LEVEL},
          message = #{connection.quote(LEGACY_DOWN_MESSAGE)},
          updated_at = CURRENT_TIMESTAMP
      WHERE event_type = #{connection.quote(STORE_OFFER_EVENT_TYPE)}
        AND source = #{connection.quote(STORE_OFFER_EVENT_SOURCE)}
        AND request_id IN (
          SELECT requests.id
          FROM requests
          WHERE requests.status = #{AWAITING_PURCHASE_STATUS}
        )
    SQL

    execute <<~SQL.squish
      UPDATE requests
      SET status = #{SEARCHING_STATUS},
          attention_needed = 1,
          issue_description = #{connection.quote(LEGACY_DOWN_MESSAGE)},
          next_retry_at = NULL,
          updated_at = CURRENT_TIMESTAMP
      WHERE status = #{AWAITING_PURCHASE_STATUS}
    SQL
  end
end
