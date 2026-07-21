# frozen_string_literal: true

require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    @user = users(:one)
  end

  test "new redirects non admin when users already exist" do
    sign_in_as(@user)

    get sign_up_url

    assert_redirected_to root_path
    assert_equal "Only admins can create new users.", flash[:alert]
  end

  test "new renders for admin" do
    sign_in_as(@admin)

    get sign_up_url

    assert_response :success
    assert_select "form[action='#{sign_up_path}']"
  end

  test "create first user starts a session and redirects to settings" do
    User.find_each(&:destroy!)

    assert_difference -> { User.count } do
      post sign_up_url, params: {
        user: {
          name: "First Admin",
          username: "first_admin",
          password: "Password123!",
          password_confirmation: "Password123!"
        }
      }
    end

    assert_redirected_to admin_settings_path
    assert_equal "Welcome! You are the admin. Please configure your settings.", flash[:notice]
    assert User.find_by!(username: "first_admin").admin?
    assert cookies["session_id"].present?
  end

  test "admin can create additional user with role" do
    sign_in_as(@admin)

    assert_difference -> { User.count } do
      post sign_up_url, params: {
        user: {
          name: "Second Admin",
          username: "second_admin",
          password: "Password123!",
          password_confirmation: "Password123!",
          role: "admin"
        }
      }
    end

    assert_redirected_to admin_users_path
    assert_equal "User created successfully.", flash[:notice]
    assert User.find_by!(username: "second_admin").admin?
  end

  test "create renders validation errors" do
    sign_in_as(@admin)

    assert_no_difference -> { User.count } do
      post sign_up_url, params: {
        user: {
          name: "",
          username: "bad username",
          password: "short",
          password_confirmation: "short",
          role: "user"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "form[action='#{sign_up_path}']"
  end
end
