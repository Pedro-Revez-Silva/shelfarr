# frozen_string_literal: true

class ExpandDefaultZlibraryUrls < ActiveRecord::Migration[8.1]
  DEFAULT_ZLIBRARY_URLS = "https://z-library.sk\nhttps://z-library.bz\nhttps://z-library.rs"

  def up
    return unless table_exists?(:settings)

    execute <<~SQL
      UPDATE settings
      SET value = #{quote(DEFAULT_ZLIBRARY_URLS)}
      WHERE key = 'zlibrary_url'
        AND value = 'https://z-library.sk'
    SQL
  end

  def down
    return unless table_exists?(:settings)

    execute <<~SQL
      UPDATE settings
      SET value = 'https://z-library.sk'
      WHERE key = 'zlibrary_url'
        AND value = #{quote(DEFAULT_ZLIBRARY_URLS)}
    SQL
  end
end
