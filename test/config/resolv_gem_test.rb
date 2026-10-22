# frozen_string_literal: true

require "test_helper"

class ResolvGemTest < ActiveSupport::TestCase
  test "activates resolv 0.3.2 or newer and does not retain unknown DNS classes" do
    spec = Gem.loaded_specs.fetch("resolv")

    assert_operator spec.version, :>=, Gem::Version.new("0.3.2")
    assert_equal spec.version.to_s, Resolv::VERSION
    refute spec.default_gem?

    type_value = 65_280
    class_value = 1
    constant_name = "Type#{type_value}_Class#{class_value}"
    refute Resolv::DNS::Resource::Generic.const_defined?(constant_name, false)

    first = decode_unknown_resource(type_value, class_value)
    second = decode_unknown_resource(type_value, class_value)

    refute Resolv::DNS::Resource::Generic.const_defined?(constant_name, false)
    refute Resolv::DNS::Resource::ClassHash.key?([ type_value, class_value ])
    refute_same first.class, second.class
  end

  private

  def decode_unknown_resource(type_value, class_value)
    name = "\x07example\x03com\x00".b
    rdata = "x".b
    packet = [ 0x1234, 0x8000, 0, 1, 0, 0 ].pack("n*") +
      name +
      [ type_value, class_value, 60, rdata.bytesize ].pack("nnNn") +
      rdata
    Resolv::DNS::Message.decode(packet).answer.fetch(0).last
  end
end
