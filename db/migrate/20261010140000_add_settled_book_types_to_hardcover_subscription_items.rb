class AddSettledBookTypesToHardcoverSubscriptionItems < ActiveRecord::Migration[8.1]
  # books.book_type as stored (Book's enum when this was written).
  BOOK_TYPES = { 0 => "audiobook", 1 => "ebook", 2 => "comicbook" }.freeze

  def up
    # Formats an item has already requested, or found in Shelfarr, so a book
    # whose other formats wait for a later run never requests them again.
    add_column :hardcover_subscription_items, :settled_book_types, :json, null: false, default: []

    # Items still waiting on some of their formats settle the formats of the requests they already recorded.
    select_rows("SELECT id, request_ids FROM hardcover_subscription_items WHERE state <> 'requested'").each do |id, raw_ids|
      ids = Array(JSON.parse(raw_ids.presence || "[]")).map(&:to_i).select(&:positive?)
      next if ids.empty?

      book_types = select_values(<<~SQL.squish).filter_map { |value| BOOK_TYPES[value.to_i] }.uniq
        SELECT DISTINCT books.book_type FROM requests INNER JOIN books ON books.id = requests.book_id
        WHERE requests.id IN (#{ids.join(', ')})
      SQL
      next if book_types.empty?

      execute("UPDATE hardcover_subscription_items SET settled_book_types = #{quote(book_types.to_json)} WHERE id = #{Integer(id)}")
    end
  end

  def down
    remove_column :hardcover_subscription_items, :settled_book_types
  end
end
