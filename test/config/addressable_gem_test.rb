# frozen_string_literal: true

require "test_helper"
require "addressable/uri"

class AddressableGemTest < ActiveSupport::TestCase
  test "activates addressable 2.9.1 or newer and keeps dotted paths and displayed hosts honest" do
    spec = Gem.loaded_specs.fetch("addressable")

    assert_operator spec.version, :>=, Gem::Version.new("2.9.1")

    path = Addressable::URI.parse("http://example.org/../../public/x/../../secret").normalize.path

    assert_equal "/secret", path

    invalid = Addressable::URI.parse("https://xn--google-.example.org/").display_uri
    bidi = Addressable::URI.parse("http://xn--abcmoc-dm0c.com/").display_uri
    displayed = Addressable::URI.parse("http://xn--bcher-kva.example/").display_uri

    assert_equal "xn--google-.example.org", invalid.host
    assert_equal "xn--abcmoc-dm0c.com", bidi.host
    assert_equal "bücher.example", displayed.host
  end
end
