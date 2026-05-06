# frozen_string_literal: true

require "test_helper"

class API::V1::RequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    SettingsService.set(:api_token, "apitoken")
    @user = users(:one)
  end

  test "creates a request for an existing Shelfarr user" do
    assert_difference [ "Book.count", "Request.count" ], 1 do
      post api_v1_requests_path,
        headers: { "Authorization" => "Bearer apitoken" },
        params: {
          username: @user.username,
          work_id: "openlibrary:OL_API_REQUEST_123W",
          book_type: "ebook",
          title: "API Request Book",
          author: "API Author"
        }
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal @user.username, body.dig("requests", 0, "user", "username")
    assert_equal "API Request Book", body.dig("requests", 0, "book", "title")
  end

  test "rejects request creation without a registered user" do
    post api_v1_requests_path,
      headers: { "Authorization" => "Bearer apitoken" },
      params: {
        username: "missing",
        work_id: "openlibrary:OL_API_MISSING_USER_123W",
        book_type: "ebook",
        title: "Missing User Book"
      }

    assert_response :not_found
  end

  test "returns validation errors from shared request creation layer" do
    post api_v1_requests_path,
      headers: { "Authorization" => "Bearer apitoken" },
      params: {
        username: @user.username,
        work_id: "openlibrary:OL_EBOOK_1",
        book_type: "ebook",
        title: "The Pending Ebook"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_includes body["errors"].join, "already has an active request"
  end
end
