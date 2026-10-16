# frozen_string_literal: true

class PreferEapiZlibraryDomains < ActiveRecord::Migration[8.1]
  class MigrationSetting < ApplicationRecord
    self.table_name = "settings"
  end

  PREVIOUS_DEFAULT = "https://z-library.sk\nhttps://z-library.bz\nhttps://z-library.rs"
  NEW_DEFAULT = %w[
    https://z-lib.gd
    https://z-lib.gl
    https://z-library.ec
    https://zlib.bz
    https://article.sk
    https://articles.sk
    https://z-library.sk
    https://z-library.bz
    https://z-library.rs
  ].join("\n")

  def up
    MigrationSetting.where(key: "zlibrary_url", value: PREVIOUS_DEFAULT).update_all(value: NEW_DEFAULT)
  end

  def down
    MigrationSetting.where(key: "zlibrary_url", value: NEW_DEFAULT).update_all(value: PREVIOUS_DEFAULT)
  end
end
