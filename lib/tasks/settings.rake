# frozen_string_literal: true

namespace :settings do
  desc "Fix corrupted JSON values in settings"
  task fix_json: :environment do
    puts "Checking for corrupted JSON settings..."

    fixed_count = 0
    Setting.where(value_type: "json").find_each do |setting|
      begin
        JSON.parse(setting.value)
        puts "  ✓ #{setting.key}: valid JSON"
      rescue JSON::ParserError
        old_value = setting.value
        puts "  ✗ #{setting.key}: invalid JSON detected - '#{old_value}'"

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
