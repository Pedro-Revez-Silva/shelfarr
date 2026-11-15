# frozen_string_literal: true

require "test_helper"

class WebPreview::AccessTest < ActiveSupport::TestCase
  test "no configuration enables nobody" do
    [ nil, "", "  " ].each do |raw|
      access = WebPreview::Access.new(raw)
      assert_not access.configured?
      assert_not access.allows?(users(:one))
    end
  end

  test "a list of user ids enables exactly those users" do
    access = WebPreview::Access.new(" #{users(:one).id} , #{users(:one).id}")
    assert access.configured?
    assert_equal [ users(:one).id ], access.user_ids
    assert access.allows?(users(:one))
    assert_not access.allows?(users(:two))
    assert_not access.allows?(nil)
  end

  test "any malformed entry disables the preview for everyone and says why" do
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    [ "abc", "1,,2", "0", "-3", "1;2", "1 2", "1.5", ",", "#{users(:one).id},all", (1..101).to_a.join(",") ].each do |raw|
      access = WebPreview::Access.new(raw)
      assert_empty access.user_ids, raw.inspect
      assert_not access.allows?(users(:one)), raw.inspect
    end
    assert_includes output.string, "#{WebPreview::Access::VARIABLE} is malformed"
  ensure
    Rails.logger = previous
  end

  test "the current configuration follows the environment" do
    with_env(WebPreview::Access::VARIABLE => users(:one).id.to_s) { assert WebPreview::Access.current.allows?(users(:one)) }
    with_env(WebPreview::Access::VARIABLE => nil) { assert_not WebPreview::Access.current.configured? }
    with_env(WebPreview::Access::VARIABLE => users(:two).id.to_s) do
      assert WebPreview::Access.current.allows?(users(:two))
      assert_not WebPreview::Access.current.allows?(users(:one))
    end
  end
end
