# frozen_string_literal: true

require "test_helper"
require "sqlite3"

class Sqlite3GemTest < ActiveSupport::TestCase
  test "activates sqlite3 2.10.2 or newer and refuses a SQL string of 2**31 bytes" do
    spec = Gem.loaded_specs.fetch("sqlite3")

    assert_operator spec.version, :>=, Gem::Version.new("2.10.2")

    database = SQLite3::Database.new(":memory:")

    assert_equal [ [ 1 ] ], database.execute("SELECT 1")

    error = assert_raises(RangeError) { database.execute("x" * (2**31)) }

    assert_match "2147483648", error.message
  end
end
