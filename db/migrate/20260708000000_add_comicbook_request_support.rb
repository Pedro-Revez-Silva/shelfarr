# frozen_string_literal: true

class AddComicbookRequestSupport < ActiveRecord::Migration[8.1]
  def change
    add_column :books, :content_kind, :integer, null: false, default: 0
    add_column :books, :comic_vine_id, :string
    add_column :books, :issue_number, :string
    add_column :books, :release_date, :date
    add_index :books, :content_kind
    add_index :books, :comic_vine_id

    add_column :requests, :request_scope, :string, null: false, default: "single"
    add_column :requests, :collection_source, :string
    add_column :requests, :collection_id, :string
    add_column :requests, :collection_title, :string
    add_index :requests, :request_scope
    add_index :requests, [ :collection_source, :collection_id ]

    add_column :acquisition_providers, :supports_comicbooks, :boolean, null: false, default: false
  end
end
