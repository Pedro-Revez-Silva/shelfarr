# frozen_string_literal: true

require "test_helper"

class Admin::DocumentationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    @user = users(:one)
  end

  test "index requires authentication" do
    get admin_documentation_url
    assert_redirected_to new_session_path
  end

  test "index requires admin" do
    sign_in_as(@user)

    get admin_documentation_url
    assert_redirected_to root_path
  end

  test "index renders configuration documentation for admins" do
    sign_in_as(@admin)

    get admin_documentation_url

    assert_response :success
    assert_select "h1", "Configuration Documentation"
    assert_select "code", text: "prowlarr_url"
    assert_select "h2", text: "Download Client Fields"
  end
end
