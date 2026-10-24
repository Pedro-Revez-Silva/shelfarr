# frozen_string_literal: true

require "test_helper"
require "crass"

class CrassGemTest < ActiveSupport::TestCase
  test "activates crass 1.0.8 or newer so a bad URL ends after an escaped backslash" do
    spec = Gem.loaded_specs.fetch("crass")

    assert_operator spec.version, :>=, Gem::Version.new("1.0.8")

    backslash = "\\"
    tokens = Crass::Tokenizer.tokenize(%(url(x"#{backslash * 2})after))

    assert_equal [ :bad_url, %(url(x"#{backslash * 2})) ], [ tokens[0][:node], tokens[0][:raw] ]
    assert_equal [ :ident, "after" ], [ tokens[1][:node], tokens[1][:raw] ]
  end
end
