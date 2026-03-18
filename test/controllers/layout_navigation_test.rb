# frozen_string_literal: true

require "test_helper"

class LayoutNavigationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
  end

  test "authenticated users see uploads navigation link even when uploads are disabled" do
    sign_in_as(@user)

    get root_url

    assert_response :success
    assert_select "a[href='#{uploads_path}']", text: "Uploads"
    assert_select "a[href='#{new_upload_path}']", text: "Upload", count: 0
  end
end
