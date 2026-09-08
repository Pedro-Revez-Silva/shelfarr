# frozen_string_literal: true

require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "oidc_auth_path is unprefixed when the app is at the root" do
    assert_equal "/auth/oidc", oidc_auth_path
  end

  test "oidc_auth_path includes the request script name" do
    @request.script_name = "/books"

    assert_equal "/books/auth/oidc", oidc_auth_path
  end
end
