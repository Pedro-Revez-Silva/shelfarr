# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261010140000_add_settled_book_types_to_hardcover_subscription_items")

class AddSettledBookTypesToHardcoverSubscriptionItemsTest < ActiveSupport::TestCase
  class IsolatedMigrationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    IsolatedMigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    @connection = IsolatedMigrationRecord.connection
    @connection.create_table(:books) { |table| table.integer :book_type, null: false }
    @connection.create_table(:requests) { |table| table.integer :book_id, null: false }
    @connection.create_table(:hardcover_subscription_items) do |table|
      table.string :state, null: false
      table.json :request_ids, null: false, default: []
    end
  end

  teardown do
    IsolatedMigrationRecord.remove_connection
  end

  test "items waiting on some formats settle the formats they already requested, and it rolls back" do
    ebook_request = insert_request(book_type: 1)
    audiobook_request = insert_request(book_type: 0)
    deferred = insert_item(state: "queued", request_ids: [ ebook_request ])
    failed = insert_item(state: "failed", request_ids: [ ebook_request, audiobook_request, 999 ])
    untouched = insert_item(state: "queued", request_ids: [])
    requested = insert_item(state: "requested", request_ids: [ audiobook_request ])
    migration = AddSettledBookTypesToHardcoverSubscriptionItems.new
    isolated_connection = @connection
    migration.define_singleton_method(:connection) { isolated_connection }

    migration.up

    assert_equal [ "ebook" ], settled(deferred)
    assert_equal %w[audiobook ebook], settled(failed).sort
    assert_equal [], settled(untouched)
    assert_equal [], settled(requested), "a finished item has nothing left to request"

    migration.down

    assert_not @connection.column_exists?(:hardcover_subscription_items, :settled_book_types)
  end

  private

  def insert_request(book_type:)
    @connection.execute("INSERT INTO books (book_type) VALUES (#{Integer(book_type)})")
    book_id = @connection.select_value("SELECT MAX(id) FROM books").to_i
    @connection.execute("INSERT INTO requests (book_id) VALUES (#{book_id})")
    @connection.select_value("SELECT MAX(id) FROM requests").to_i
  end

  def insert_item(state:, request_ids:)
    @connection.execute("INSERT INTO hardcover_subscription_items (state, request_ids) VALUES (#{@connection.quote(state)}, #{@connection.quote(request_ids.to_json)})")
    @connection.select_value("SELECT MAX(id) FROM hardcover_subscription_items").to_i
  end

  def settled(id)
    JSON.parse(@connection.select_value("SELECT settled_book_types FROM hardcover_subscription_items WHERE id = #{Integer(id)}"))
  end
end
