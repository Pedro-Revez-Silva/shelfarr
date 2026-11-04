# frozen_string_literal: true

require "test_helper"
require "nokogiri"

class NokogiriGemTest < ActiveSupport::TestCase
  test "activates nokogiri 1.19.5 or newer and escapes markup in attributes and noscript text" do
    spec = Gem.loaded_specs.fetch("nokogiri")

    assert_operator spec.version, :>=, Gem::Version.new("1.19.5")
    assert_equal spec.version.to_s, Nokogiri::VERSION

    fragment = Nokogiri::HTML5.fragment(%(<div title="a<b>">x</div>))

    assert_equal %(<div title="a&lt;b&gt;">x</div>), fragment.to_html

    document = Nokogiri::HTML5.parse("<body><noscript>before</noscript></body>")
    noscript = document.at_css("noscript")
    noscript.add_child(Nokogiri::XML::Text.new("<script>alert(1)</script>", document))

    assert_equal "<noscript>before&lt;script&gt;alert(1)&lt;/script&gt;</noscript>", noscript.to_html

    link = Nokogiri::HTML5.fragment(%(<a href="old">text</a>)).at_css("a")
    previous = link.attribute("href").children.first
    link["href"] = "replacement"

    assert_equal "replacement", link["href"]
    assert_equal "old", previous.content
  end
end
