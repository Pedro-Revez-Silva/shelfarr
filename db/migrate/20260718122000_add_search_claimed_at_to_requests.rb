# frozen_string_literal: true

class AddSearchClaimedAtToRequests < ActiveRecord::Migration[8.1]
  SEARCHING_STATUS = 1

  def up
    add_column :requests, :search_claimed_at, :datetime
    add_index :requests, [ :status, :search_claimed_at ]

    # Existing manual-review searches deliberately remain in `searching`. Their
    # terminal attention event is written after the request update. Older
    # Shelfarr could then refresh that request without clearing attention; its
    # later search claim advances updated_at beyond the old event. Use that
    # durable ordering to distinguish the ambiguous legacy states so a worker
    # killed by deployment is recoverable without re-running finished reviews.
    attention_condition = if connection.adapter_name == "PostgreSQL"
      "COALESCE(attention_needed, FALSE) = FALSE"
    else
      "COALESCE(attention_needed, 0) = 0"
    end

    execute <<~SQL.squish
      UPDATE requests
      SET search_claimed_at = updated_at
      WHERE status = #{SEARCHING_STATUS}
        AND search_claimed_at IS NULL
        AND (
          #{attention_condition}
          OR NOT EXISTS (
            SELECT 1
            FROM request_events
            WHERE request_events.request_id = requests.id
              AND request_events.event_type = 'attention_flagged'
              AND request_events.source = 'request'
              AND request_events.created_at >= requests.updated_at
          )
        )
    SQL
  end

  def down
    remove_index :requests, [ :status, :search_claimed_at ]
    remove_column :requests, :search_claimed_at
  end
end
