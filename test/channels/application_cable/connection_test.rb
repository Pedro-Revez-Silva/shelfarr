# frozen_string_literal: true

require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "connects with signed session cookie" do
    user = users(:one)
    session = user.sessions.create!
    cookies.signed[:session_id] = session.id

    connect

    assert_equal user, connection.current_user
  end

  test "rejects connections without a valid session" do
    assert_reject_connection { connect }
  end
end
