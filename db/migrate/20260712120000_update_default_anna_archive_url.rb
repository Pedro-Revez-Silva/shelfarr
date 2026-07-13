class UpdateDefaultAnnaArchiveUrl < ActiveRecord::Migration[8.1]
  class MigrationSetting < ApplicationRecord
    self.table_name = "settings"
  end

  OLD_DEFAULT = "https://annas-archive.se"
  NEW_DEFAULT = "https://annas-archive.gl"

  def up
    MigrationSetting.where(key: "anna_archive_url", value: OLD_DEFAULT).update_all(value: NEW_DEFAULT)
  end

  def down
    MigrationSetting.where(key: "anna_archive_url", value: NEW_DEFAULT).update_all(value: OLD_DEFAULT)
  end
end
