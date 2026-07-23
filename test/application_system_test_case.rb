require "test_helper"

module ChromeStaleNodeVisibilityRetry
  def visible?
    super
  rescue Selenium::WebDriver::Error::UnknownError => error
    raise unless error.message.include?("Node with given id does not belong to the document")

    raise Selenium::WebDriver::Error::StaleElementReferenceError, error.message
  end
end

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ],
    options: { native_displayed: true } do |options|
    options.add_argument("--no-sandbox") if Process.uid.zero?
  end

  def sign_in_as(user)
    session = user.sessions.create!
    signed_session_id = ActionDispatch::TestRequest.create.cookie_jar.tap do |cookie_jar|
      cookie_jar.signed[:session_id] = session.id
    end[:session_id]

    visit root_path
    page.driver.browser.manage.add_cookie(name: "session_id", value: signed_session_id, path: "/")
  end
end

Capybara::Selenium::ChromeNode.prepend(ChromeStaleNodeVisibilityRetry)
