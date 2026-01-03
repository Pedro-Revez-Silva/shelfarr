class SplitAudiobookshelfLibraryId < ActiveRecord::Migration[8.1]
  def up
    # Get the existing library_id value
    old_setting = execute("SELECT value FROM settings WHERE key = 'audiobookshelf_library_id'").first
    old_value = old_setting&.fetch("value", "") || ""

    # Create new audiobook library setting with old value
    execute <<-SQL
      INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at)
      VALUES ('audiobookshelf_audiobook_library_id', '#{old_value}', 'string', 'audiobookshelf', 'Library ID for audiobooks', datetime('now'), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')
    SQL

    # Create new ebook library setting with old value
    execute <<-SQL
      INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at)
      VALUES ('audiobookshelf_ebook_library_id', '#{old_value}', 'string', 'audiobookshelf', 'Library ID for ebooks', datetime('now'), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')
    SQL

    # Delete old setting
    execute("DELETE FROM settings WHERE key = 'audiobookshelf_library_id'")
  end

  def down
    # Get audiobook library setting (prefer this one for rollback)
    audiobook_setting = execute("SELECT value FROM settings WHERE key = 'audiobookshelf_audiobook_library_id'").first
    old_value = audiobook_setting&.fetch("value", "") || ""

    # Recreate old setting
    execute <<-SQL
      INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at)
      VALUES ('audiobookshelf_library_id', '#{old_value}', 'string', 'audiobookshelf', 'Target library ID for imported content', datetime('now'), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')
    SQL

    # Delete new settings
    execute("DELETE FROM settings WHERE key = 'audiobookshelf_audiobook_library_id'")
    execute("DELETE FROM settings WHERE key = 'audiobookshelf_ebook_library_id'")
  end
end
