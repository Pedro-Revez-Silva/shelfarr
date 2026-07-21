# frozen_string_literal: true

require "test_helper"

class SettingTest < ActiveSupport::TestCase
  test "typed_value casts scalar values" do
    assert_equal "value", Setting.new(value_type: "string", value: "value").typed_value
    assert_equal 42, Setting.new(value_type: "integer", value: "42").typed_value
    assert_equal true, Setting.new(value_type: "boolean", value: "1").typed_value
  end

  test "typed_value parses json and recovers corrupted json" do
    assert_equal [ "a", "b" ], Setting.new(value_type: "json", value: "[\"a\",\"b\"]").typed_value
    assert_equal [ "a", "b" ], Setting.new(key: "broken", value_type: "json", value: "a,b").typed_value
    assert_equal [ "a" ], Setting.new(key: "broken", value_type: "json", value: "a").typed_value
  end

  test "typed_value writer preserves valid json and normalizes invalid json" do
    setting = Setting.new(value_type: "json")

    setting.typed_value = "[\"a\"]"
    assert_equal "[\"a\"]", setting.value

    setting.typed_value = "a,b"
    assert_equal [ "a", "b" ], JSON.parse(setting.value)

    setting.typed_value = "single"
    assert_equal [ "single" ], JSON.parse(setting.value)

    setting.typed_value = [ "x" ]
    assert_equal [ "x" ], JSON.parse(setting.value)
  end

  test "typed_value writer stringifies non json values" do
    setting = Setting.new(value_type: "integer")

    setting.typed_value = 12

    assert_equal "12", setting.value
  end
end
