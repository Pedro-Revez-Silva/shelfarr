# frozen_string_literal: true

require "test_helper"
require "sqlite3"

class Sqlite3GemTest < ActiveSupport::TestCase
  test "activates sqlite3 2.10.2 or newer and refuses a SQL string longer than INT_MAX" do
    spec = Gem.loaded_specs.fetch("sqlite3")

    assert_operator spec.version, :>=, Gem::Version.new("2.10.2")
    assert_equal spec.version.to_s, SQLite3::VERSION

    database = SQLite3::Database.new(":memory:")
    assert_equal 1, database.get_first_value("select 1")

    oversized = "\0" * (2**31)
    error = assert_raises(RangeError) { SQLite3::Statement.new(database, oversized) }

    assert_match "2147483648", error.message
  ensure
    database&.close
  end
end
