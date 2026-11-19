# frozen_string_literal: true

module Migration
  module Browser
    module MetadataSettings
      METADATA_KEYS = %w[open_library_enabled open_library_search_limit].freeze
      METADATA_ROW_COLUMNS = %w[key value value_type category description].freeze
      METADATA_FORMS = {
        "open_library_enabled" => [
          %w[true boolean], %w[false boolean], %w[1 boolean], %w[0 boolean], %w[f boolean], %w[off boolean], %w[yes boolean],
          [ "", "boolean" ], [ nil, "boolean" ], %w[false string], %w[0 integer]
        ],
        "open_library_search_limit" => [
          %w[15 integer], [ " 0d1_5 ", "integer" ], %w[50 integer], %w[-3 integer], %w[0 integer], %w[1_000 integer], [ nil, "integer" ],
          %w[12abc integer], %w[many integer], %w[12 string]
        ]
      }.freeze
      METADATA_WRITES = [ %w[open_library_enabled false], %w[open_library_search_limit 15] ].freeze

      def capture_metadata_settings
        {
          "definitions" => METADATA_KEYS.to_h { |key| [ key, metadata_definition(key) ] },
          "fixture_values" => METADATA_KEYS.to_h { |key| [ key, SettingsService.get(key) ] },
          "fixture_rows" => Setting.where(key: METADATA_KEYS).order(:key).map { |row| row.slice(*METADATA_ROW_COLUMNS) },
          "environment_ignored" => METADATA_KEYS.to_h { |key| [ key, environment_read(key) ] },
          "reads" => METADATA_FORMS.flat_map { |key, forms| forms.map { |value, type| rails_read(key, value, type) } },
          "inserted" => metadata_rolled_back { rails_writes },
          "updated" => metadata_rolled_back do
            METADATA_KEYS.each { |key| Setting.where(key: key).delete_all }
            Setting.create!(key: "open_library_enabled", value: "0", value_type: "string", category: "legacy", description: "old")
            Setting.create!(key: "open_library_search_limit", value: "many", value_type: "string", category: "legacy", description: "old")
            rails_writes
          end
        }
      end

      private

      def metadata_definition(key)
        definition = SettingsService::DEFINITIONS.fetch(key.to_sym)
        { "type" => definition[:type], "default" => definition[:default], "category" => definition[:category], "description" => definition[:description],
          "env_overridable" => definition.fetch(:env_overridable, false) }
      end

      def environment_read(key)
        name = SettingsService.env_override_name(key)
        ENV[name] = key == "open_library_enabled" ? "false" : "3"
        { "variable" => name, "env_managed" => SettingsService.env_managed?(key), "value" => SettingsService.get(key) }
      ensure
        ENV.delete(name)
      end

      def rails_read(key, value, type)
        metadata_rolled_back do
          Setting.where(key: key).delete_all
          Setting.create!(key: key, value: value, value_type: type, category: "open_library")
          read = SettingsService.get(key)
          { "key" => key, "value" => value, "value_type" => type, "rails" => read, "rails_class" => read.class.name }
        end
      end

      def rails_writes
        METADATA_WRITES.map do |key, value|
          SettingsService.set(key, value)
          Setting.find_by!(key: key).slice(*METADATA_ROW_COLUMNS)
        end
      end

      def metadata_rolled_back
        result = nil
        ActiveRecord::Base.transaction do
          result = yield
          raise ActiveRecord::Rollback
        end
        result
      end
    end
  end
end
