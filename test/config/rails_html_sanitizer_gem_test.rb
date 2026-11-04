# frozen_string_literal: true

require "test_helper"

class RailsHtmlSanitizerGemTest < ActiveSupport::TestCase
  test "activates rails-html-sanitizer 1.7.2 or newer and does not share scrubber options across calls" do
    spec = Gem.loaded_specs.fetch("rails-html-sanitizer")

    assert_operator spec.version, :>=, Gem::Version.new("1.7.2")
    assert_equal spec.version.to_s, Rails::HTML::Sanitizer::VERSION

    sanitizer = Rails::HTML5::SafeListSanitizer.new
    permissive_result = nil
    strict_options = { tags: %w[div], attributes: [] }
    strict_options.define_singleton_method(:[]) do |key|
      if key == :attributes && permissive_result.nil?
        permissive_result = sanitizer.sanitize("<script>alert(2)</script>", tags: %w[script], attributes: [])
      end
      super(key)
    end

    strict_result = sanitizer.sanitize("<div>x</div><script>alert(1)</script>", strict_options)

    assert_equal "<script>alert(2)</script>", permissive_result
    assert_equal "<div>x</div>alert(1)", strict_result
  end
end
