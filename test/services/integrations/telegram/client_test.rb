# frozen_string_literal: true

require "test_helper"

module Integrations
  module Telegram
    class ClientTest < ActiveSupport::TestCase
      test "get_updates keeps the HTTP read timeout above the Telegram polling timeout" do
        client = Client.new
        captured = {}

        client.define_singleton_method(:post) do |method, payload, request_timeout: nil|
          captured[:method] = method
          captured[:payload] = payload
          captured[:request_timeout] = request_timeout
          { "ok" => true, "result" => [] }
        end

        client.get_updates(timeout: 20, limit: 20)

        assert_equal "getUpdates", captured[:method]
        assert_equal 20, captured[:payload][:timeout]
        assert_equal 25, captured[:request_timeout]
      end
    end
  end
end
