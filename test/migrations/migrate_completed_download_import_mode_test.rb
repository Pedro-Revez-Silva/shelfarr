# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260721120000_migrate_completed_download_import_mode")

class MigrateCompletedDownloadImportModeTest < ActiveSupport::TestCase
  setup do
    Setting.where(key: %w[move_completed_downloads completed_download_import_mode]).delete_all
  end

  teardown do
    Setting.where(key: %w[move_completed_downloads completed_download_import_mode]).delete_all
  end

  test "matches ActiveModel boolean casting for legacy values" do
    boolean_type = ActiveModel::Type::Boolean.new
    legacy_values = [
      nil, "",
      "0", "f", "F", "false", "FALSE", "off", "OFF",
      "true", "1", "t", "TRUE", "on", "yes", "enabled", "False",
      " false ", " off ", " ", "\t"
    ]

    legacy_values.each do |legacy_value|
      clear_import_settings
      create_setting("move_completed_downloads", legacy_value, "boolean")

      migration.up

      expected_mode = boolean_type.cast(legacy_value) ? "move" : "copy"
      assert_import_mode expected_mode, "legacy value #{legacy_value.inspect}"
      assert_not Setting.exists?(key: "move_completed_downloads")
    end
  end

  test "reverses move to legacy true" do
    create_setting("completed_download_import_mode", "move", "string")

    migration.down

    assert_legacy_move_value "true"
    assert_not Setting.exists?(key: "completed_download_import_mode")
  end

  test "migrates a missing legacy row to copy" do
    migration.up

    assert_import_mode "copy"
  end

  test "preserves every valid explicit new mode and removes the legacy row" do
    %w[copy move hardlink].each do |mode|
      clear_import_settings
      create_setting("move_completed_downloads", "true", "boolean")
      create_setting("completed_download_import_mode", mode, "boolean")

      migration.up

      assert_import_mode mode
      assert_not Setting.exists?(key: "move_completed_downloads")
    end
  end

  test "replaces an invalid new mode using the legacy value" do
    create_setting("move_completed_downloads", "true", "boolean")
    create_setting("completed_download_import_mode", "rename", "string")

    migration.up

    assert_import_mode "move"
  end

  test "maps copy and hardlink to false when reversed" do
    %w[copy hardlink].each do |mode|
      Setting.where(key: %w[move_completed_downloads completed_download_import_mode]).delete_all
      create_setting("completed_download_import_mode", mode, "string")

      migration.down

      assert_legacy_move_value "false"
      assert_not Setting.exists?(key: "completed_download_import_mode")
    end
  end

  private

  def migration
    MigrateCompletedDownloadImportMode.new
  end

  def clear_import_settings
    Setting.where(key: %w[move_completed_downloads completed_download_import_mode]).delete_all
  end

  def create_setting(key, value, value_type)
    Setting.create!(
      key: key,
      value: value,
      value_type: value_type,
      category: "download",
      description: "Test setting"
    )
  end

  def assert_import_mode(expected, message = nil)
    setting = Setting.find_by!(key: "completed_download_import_mode")
    assert_equal expected, setting.value, message
    assert_equal "string", setting.value_type
    assert_equal "download", setting.category
  end

  def assert_legacy_move_value(expected)
    setting = Setting.find_by!(key: "move_completed_downloads")
    assert_equal expected, setting.value
    assert_equal "boolean", setting.value_type
    assert_equal "download", setting.category
  end
end
