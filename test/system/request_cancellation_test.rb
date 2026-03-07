require "application_system_test_case"

class RequestCancellationTest < ApplicationSystemTestCase
  test "cancelling from the request details page returns to the requests list" do
    request_record = requests(:pending_request)
    sign_in_as(users(:one))

    visit request_path(request_record)
    click_button "Cancel Request", match: :first

    assert_selector "dialog[open]"

    within "dialog[open]" do
      click_button "Cancel Request"
    end

    assert_current_path requests_path, wait: 5
    assert_text "Request cancelled"
  end

  private

  def sign_in_as(user)
    session = user.sessions.create!
    signed_session_id = ActionDispatch::TestRequest.create.cookie_jar.tap do |cookie_jar|
      cookie_jar.signed[:session_id] = session.id
    end[:session_id]

    visit root_path
    page.driver.browser.manage.add_cookie(name: "session_id", value: signed_session_id, path: "/")
  end
end
