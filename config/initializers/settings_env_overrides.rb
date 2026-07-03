Rails.application.config.after_initialize do
  SettingsService.unrecognized_env_override_names.each do |env_name|
    Rails.logger.warn "[Shelfarr] #{env_name} does not match an env-overridable setting and has no effect."
  end

  managed_keys = SettingsService.env_managed_keys.map(&:to_s).sort
  Rails.logger.info "[Shelfarr] Env-managed settings in effect: #{managed_keys.join(', ')}" if managed_keys.any?
end
