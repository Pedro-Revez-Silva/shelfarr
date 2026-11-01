# frozen_string_literal: true

require "test_helper"
require "addressable/uri"

class AddressableGemTest < ActiveSupport::TestCase
  test "activates addressable 2.9.1 or newer, resolves dotted paths, and leaves an invalid display host unchanged" do
    spec = Gem.loaded_specs.fetch("addressable")

    assert_operator spec.version, :>=, Gem::Version.new("2.9.1")

    assert_equal "/secret", Addressable::URI.normalize_path("/../../public/x/../../secret")

    misleading = Addressable::URI.parse("https://xn--google-.example.org/")
    assert_equal "xn--google-.example.org", misleading.display_uri.host

    bidi = Addressable::URI.parse("http://xn--abcmoc-dm0c.com/")
    assert_equal "xn--abcmoc-dm0c.com", bidi.display_uri.host

    books = Addressable::URI.parse("https://xn--bcher-kva.example/")
    assert_equal "bücher.example", books.display_uri.host
    assert_equal "xn--bcher-kva.example", books.host
  end
end
