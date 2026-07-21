# frozen_string_literal: true

class MigrateCompletedDownloadImportMode < ActiveRecord::Migration[8.1]
  class MigrationSetting < ActiveRecord::Base
    self.table_name = "settings"
  end

  OLD_KEY = "move_completed_downloads"
  NEW_KEY = "completed_download_import_mode"
  VALID_MODES = %w[copy move hardlink].freeze
  LEGACY_BOOLEAN_TYPE = ActiveModel::Type::Boolean.new
  DESCRIPTION = "Choose Copy, Move, or Hardlink. Hardlink requires one container-visible filesystem; unsupported or cross-filesystem links fall back to copy."

  def up
    return unless table_exists?(:settings)

    legacy_setting = MigrationSetting.find_by(key: OLD_KEY)
    import_mode_setting = MigrationSetting.find_or_initialize_by(key: NEW_KEY)
    import_mode = if import_mode_setting.persisted? && VALID_MODES.include?(import_mode_setting.value)
      import_mode_setting.value
    elsif legacy_true?(legacy_setting&.value)
      "move"
    else
      "copy"
    end

    import_mode_setting.assign_attributes(setting_attributes(NEW_KEY, import_mode, "string", DESCRIPTION))
    import_mode_setting.save!
    legacy_setting&.delete
  end

  def down
    return unless table_exists?(:settings)

    import_mode_setting = MigrationSetting.find_by(key: NEW_KEY)
    legacy_value = import_mode_setting&.value == "move" ? "true" : "false"
    legacy_setting = MigrationSetting.find_or_initialize_by(key: OLD_KEY)
    legacy_setting.assign_attributes(
      setting_attributes(
        OLD_KEY,
        legacy_value,
        "boolean",
        "Move completed download files into the library instead of copying them. Disable to preserve torrent seeding."
      )
    )
    legacy_setting.save!
    import_mode_setting&.delete
  end

  private

  def legacy_true?(value)
    LEGACY_BOOLEAN_TYPE.cast(value) == true
  end

  def setting_attributes(key, value, value_type, description)
    {
      key: key,
      value: value,
      value_type: value_type,
      category: "download",
      description: description
    }
  end
end
