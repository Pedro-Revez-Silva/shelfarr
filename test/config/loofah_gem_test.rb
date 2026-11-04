# frozen_string_literal: true

require "test_helper"
require "loofah"

class LoofahGemTest < ActiveSupport::TestCase
  test "activates loofah 2.25.3 or newer and keeps escaped CSS urls and external SVG hrefs out" do
    spec = Gem.loaded_specs.fetch("loofah")

    assert_operator spec.version, :>=, Gem::Version.new("2.25.3")
    assert_equal spec.version.to_s, Loofah::VERSION

    refute Loofah::HTML5::Scrub.allowed_uri?("javascript&#x3a alert(1)")
    refute Loofah::HTML5::Scrub.allowed_uri?("data:text&sol;html,<script>alert(1)</script>")
    assert Loofah::HTML5::Scrub.allowed_uri?("https://example.com")

    css = Loofah::HTML5::Scrub.scrub_css("list-style:url\\28 http://example.com/b.png\\29")

    assert_equal "list-style:url\\28 http://example.com/b.png\\29;", css
    refute_includes css, "url("

    svg = %(<svg><textPath href="http://bad.com/foo"></textPath><mpath href="#local"></mpath></svg>)
    sanitized = Loofah.html5_fragment(svg).scrub!(:prune).to_html

    assert_equal %(<svg><textPath></textPath><mpath href="#local"></mpath></svg>), sanitized
  end
end
