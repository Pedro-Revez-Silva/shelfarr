# frozen_string_literal: true

namespace :settings do
  desc "Fix corrupted JSON values in settings"
  task fix_json: :environment do
    puts "Checking for corrupted JSON settings..."

    fixed_count = 0
    Setting.where(value_type: "json").find_each do |setting|
      begin
        # Try to parse the current value
        JSON.parse(setting.value)
        puts "  ✓ #{setting.key}: valid JSON"
      rescue JSON::ParserError
        # Invalid JSON - fix it
        old_value = setting.value
        puts "  ✗ #{setting.key}: invalid JSON detected - '#{old_value}'"

        # The typed_value getter will handle the conversion
        # Then we save it back using the typed_value setter
        fixed_value = setting.typed_value
        setting.typed_value = fixed_value

        if setting.save
          puts "    → Fixed: '#{old_value}' → '#{setting.value}'"
          fixed_count += 1
        else
          puts "    → Error saving: #{setting.errors.full_messages.join(', ')}"
        end
      end
    end

    if fixed_count > 0
      puts "\n✓ Fixed #{fixed_count} corrupted JSON setting(s)"
    else
      puts "\n✓ No corrupted JSON settings found"
    end
  end
end
