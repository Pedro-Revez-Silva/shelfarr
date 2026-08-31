# frozen_string_literal: true

# Ensure Rails application timezone is synchronized with the TZ environment variable.
# This initializer runs after application configuration to guarantee the timezone
# is properly applied even if there are initialization order issues.
if ENV["TZ"].present?
  begin
    # Validate that the TZ value is a recognized timezone
    Time.find_zone!(ENV["TZ"])
    
    # Explicitly set the application timezone
    # This is redundant with config.time_zone in application.rb but provides
    # a fail-safe in case of initialization order issues
    Rails.application.config.time_zone = ENV["TZ"]
    Rails.logger.info "Application timezone set to: #{ENV['TZ']}"
  rescue ArgumentError => e
    # TZ value is not a valid timezone identifier
    Rails.logger.warn "Invalid TZ environment variable '#{ENV['TZ']}': #{e.message}. Falling back to UTC."
    Rails.application.config.time_zone = "UTC"
  end
end
