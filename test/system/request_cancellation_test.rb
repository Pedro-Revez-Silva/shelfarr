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
end
