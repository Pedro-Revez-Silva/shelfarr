# frozen_string_literal: true

require "capybara/selenium/driver_specializations/chrome_driver"

# Chrome 158 rejects Storage.clearDataForOrigin with origin "*".
# Cookies still clear for every host. Local storage clears for the app server.
module ChromeStorageReset
  private

  def execute_cdp(cmd, params = {})
    return super unless cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"

    super("Network.clearBrowserCookies")
    return unless params[:storageTypes].to_s.include?("local_storage")

    origin = Capybara.current_session.server&.base_url
    return if origin.blank?

    super(cmd, { origin: origin, storageTypes: "local_storage" })
  end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeStorageReset)
