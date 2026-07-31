# frozen_string_literal: true

# Records exactly which library entries an import published, so a rollback or an
# admin undo reverses only this import's own files instead of recursively
# deleting a templated destination directory it may share with other books.
class AddPublicationRecordToDetectedImports < ActiveRecord::Migration[8.1]
  def change
    add_column :detected_imports, :publication_record, :json
  end
end
