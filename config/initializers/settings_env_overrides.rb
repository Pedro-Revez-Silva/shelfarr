Rails.application.config.after_initialize do
  env_names = ENV.keys.select { |name| name.start_with?(SettingsService::ENV_OVERRIDE_PREFIX) }

  env_names.each do |env_name|
    setting_key = env_name.delete_prefix(SettingsService::ENV_OVERRIDE_PREFIX).downcase.to_sym
    definition = SettingsService::DEFINITIONS[setting_key]

    next if definition&.fetch(:env_overridable, false) == true && env_name == SettingsService.env_override_name(setting_key)

    Rails.logger.warn "[Shelfarr] #{env_name} does not match an env-overridable setting and has no effect."
  end

  managed_keys = SettingsService.env_managed_keys.map(&:to_s).sort
  Rails.logger.info "[Shelfarr] Env-managed settings in effect: #{managed_keys.join(', ')}" if managed_keys.any?
end
