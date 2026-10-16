class SplitAudiobookshelfLibraryId < ActiveRecord::Migration[8.1]
  def up
    old_setting = execute("SELECT value FROM settings WHERE key = 'audiobookshelf_library_id'").first
    old_value = old_setting&.fetch("value", "") || ""

    execute <<-SQL
      INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at)
      VALUES ('audiobookshelf_audiobook_library_id', '#{old_value}', 'string', 'audiobookshelf', 'Library ID for audiobooks', datetime('now'), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')
    SQL

    execute <<-SQL
      INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at)
      VALUES ('audiobookshelf_ebook_library_id', '#{old_value}', 'string', 'audiobookshelf', 'Library ID for ebooks', datetime('now'), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')
    SQL

    execute("DELETE FROM settings WHERE key = 'audiobookshelf_library_id'")
  end

  def down
    audiobook_setting = execute("SELECT value FROM settings WHERE key = 'audiobookshelf_audiobook_library_id'").first
    old_value = audiobook_setting&.fetch("value", "") || ""

    execute <<-SQL
      INSERT INTO settings (key, value, value_type, category, description, created_at, updated_at)
      VALUES ('audiobookshelf_library_id', '#{old_value}', 'string', 'audiobookshelf', 'Target library ID for imported content', datetime('now'), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')
    SQL

    execute("DELETE FROM settings WHERE key = 'audiobookshelf_audiobook_library_id'")
    execute("DELETE FROM settings WHERE key = 'audiobookshelf_ebook_library_id'")
  end
end
