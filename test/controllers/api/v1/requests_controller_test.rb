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
    assert_equal "api", body.dig("requests", 0, "request", "created_via")
    assert_equal "api", body.dig("requests", 0, "request", "external_source")
  end

  test "creates request with all candidate source work ids" do
    assert_difference [ "Book.count", "Request.count" ], 1 do
      post api_v1_requests_path,
        headers: { "Authorization" => "Bearer apitoken" },
        params: {
          username: @user.username,
          work_id: "openlibrary:OL_API_MULTI_SOURCE_W",
          source_work_ids: [ "openlibrary:OL_API_MULTI_SOURCE_W", "google_books:gb-api-source" ],
          book_type: "ebook",
          title: "API Multi Source Book"
        }
    end

    assert_response :created
    book = Request.last.book
    assert_equal "OL_API_MULTI_SOURCE_W", book.open_library_work_id
    assert_equal "gb-api-source", book.google_books_id
  end

  test "blocks API request when alternate candidate source has active request" do
    book = Book.create!(title: "Existing Google API Book", book_type: :ebook, google_books_id: "gb-api-existing")
    Request.create!(book: book, user: @user, status: :pending)

    post api_v1_requests_path,
      headers: { "Authorization" => "Bearer apitoken" },
      params: {
        username: @user.username,
        work_id: "openlibrary:OL_API_NEW_SOURCE_W",
        source_work_ids: [ "google_books:gb-api-existing" ],
        book_type: "ebook",
        title: "Existing Google API Book"
      }

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "already has an active request"
  end

  test "creates a request for the scoped token user when no user is supplied" do
    _token, raw = APIToken.issue!(
      name: "Requester",
      user: @user,
      scopes: %w[requests:write]
    )

    assert_difference [ "Book.count", "Request.count" ], 1 do
      post api_v1_requests_path,
        headers: { "Authorization" => "Bearer #{raw}" },
        params: {
          work_id: "openlibrary:OL_SCOPED_API_REQUEST_123W",
          book_type: "ebook",
          title: "Scoped API Request Book"
        }
    end

    assert_response :created
    assert_equal @user, Request.last.user
  end

  test "scoped user token cannot create requests for another user" do
    _token, raw = APIToken.issue!(
      name: "Requester",
      user: @user,
      scopes: %w[requests:write]
    )

    post api_v1_requests_path,
      headers: { "Authorization" => "Bearer #{raw}" },
      params: {
        username: users(:two).username,
        work_id: "openlibrary:OL_FORBIDDEN_API_REQUEST_123W",
        book_type: "ebook",
        title: "Forbidden API Request Book"
      }

    assert_response :not_found
  end

  test "lists requests visible to scoped token user" do
    _token, raw = APIToken.issue!(
      name: "Reader",
      user: @user,
      scopes: %w[requests:read]
    )

    get api_v1_requests_path,
      headers: { "Authorization" => "Bearer #{raw}" }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["requests"].all? { |request| request.dig("user", "username") == @user.username }
  end

  test "requires request write scope to create" do
    _token, raw = APIToken.issue!(
      name: "Reader",
      user: @user,
      scopes: %w[requests:read]
    )

    post api_v1_requests_path,
      headers: { "Authorization" => "Bearer #{raw}" },
      params: {
        work_id: "openlibrary:OL_SCOPE_DENIED_123W",
        book_type: "ebook",
        title: "Denied API Request Book"
      }

    assert_response :forbidden
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

  test "shows a request for legacy admin token" do
    request = requests(:pending_request)

    get api_v1_request_path(request),
      headers: { "Authorization" => "Bearer apitoken" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal request.id, body["id"]
    assert_equal request.book.title, body.dig("book", "title")
  end

  test "filters listed requests by status and created_via with limit" do
    requests(:pending_request).update!(created_via: "api")
    requests(:failed_request).update!(created_via: "telegram")

    get api_v1_requests_path(status: "pending", created_via: "api", limit: 1),
      headers: { "Authorization" => "Bearer apitoken" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["requests"].size
    assert_equal "pending", body.dig("requests", 0, "status")
    assert_equal "api", body.dig("requests", 0, "request", "created_via")
  end

  test "legacy admin token can create request by user id with multiple book types" do
    assert_difference "Request.count", 2 do
      post api_v1_requests_path,
        headers: { "Authorization" => "Bearer apitoken" },
        params: {
          user_id: @user.id,
          work_id: "openlibrary:OL_MULTI_API_REQUEST_123W",
          book_types: %w[ebook audiobook],
          title: "Multi API Request"
        }
    end

    assert_response :created
  end

  test "cancels a cancellable request" do
    request = requests(:pending_request)

    delete api_v1_request_path(request),
      headers: { "Authorization" => "Bearer apitoken" }

    assert_response :success
    assert_equal "failed", request.reload.status
  end

  test "rejects cancel for completed request" do
    request = Request.create!(book: books(:audiobook_acquired), user: @user, status: :completed)

    delete api_v1_request_path(request),
      headers: { "Authorization" => "Bearer apitoken" }

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "Cannot cancel"
  end

  test "retries retryable request" do
    request = requests(:not_found_waiting)

    post retry_api_v1_request_path(request),
      headers: { "Authorization" => "Bearer apitoken" }

    assert_response :success
    assert_equal "pending", request.reload.status
  end

  test "rejects retry for completed request" do
    request = Request.create!(book: books(:audiobook_acquired), user: @user, status: :completed)

    post retry_api_v1_request_path(request),
      headers: { "Authorization" => "Bearer apitoken" }

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"].join, "cannot be retried"
  end
end
