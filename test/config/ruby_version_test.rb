# frozen_string_literal: true

require "test_helper"

class RubyVersionTest < ActiveSupport::TestCase
  test "runs Ruby 3.3.13 or newer" do
    assert_operator Gem::Version.new(RUBY_VERSION), :>=, Gem::Version.new("3.3.13")
  end
end
