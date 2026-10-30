# frozen_string_literal: true

require "test_helper"

class FilenameBytesTest < ActiveSupport::TestCase
  test "utf8 retags valid non-ASCII bytes without changing them" do
    utf8_name = "Jürgen Weiß"
    binary_name = utf8_name.dup.force_encoding(Encoding::ASCII_8BIT)

    tagged = FilenameBytes.utf8(binary_name)

    assert_equal utf8_name, tagged
    assert_equal Encoding::UTF_8, tagged.encoding
    assert_equal Encoding::ASCII_8BIT, binary_name.encoding
  end

  test "utf8 raises when the bytes are not valid UTF-8" do
    invalid = "bad-\xFF".b

    error = assert_raises(EncodingError) do
      FilenameBytes.utf8(invalid)
    end

    assert_match(/UTF-8/, error.message)
    assert_equal Encoding::ASCII_8BIT, invalid.encoding
  end
end
