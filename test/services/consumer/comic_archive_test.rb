# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/fixed_layout_fixtures"

class Consumer::ComicArchiveTest < ActiveSupport::TestCase
  include FixedLayoutFixtures

  setup { @directory = Dir.mktmpdir("comic-archive") }
  teardown { FileUtils.remove_entry(@directory) }

  def pages_of(bytes)
    path = File.join(@directory, "comic-#{SecureRandom.hex(4)}.cbz")
    File.binwrite(path, bytes)
    File.open(path, "rb") { |file| Consumer::ComicArchive.pages(file) }
  end

  def assert_refused(bytes, message = nil)
    assert_raises(Consumer::ComicArchive::Invalid, message) { pages_of(bytes) }
  end

  test "pages are naturally ordered with exact ZIP coordinates and metadata files are not pages" do
    png = fixed_layout_png(width: 4, height: 4)
    bytes = fixed_layout_zip({ "Vol 1/page10.png" => png, "Vol 1/page2.png" => png, "Vol 1/Page1.PNG" => png,
      "Vol 1/" => "", "ComicInfo.xml" => "<ComicInfo/>", "__MACOSX/Vol 1/._page2.png" => "fork", ".hidden.jpg" => png,
      "Vol 1/café 3.webp" => { data: "RIFF....WEBP", method: 0 } })
    pages = pages_of(bytes)
    # Case-insensitive natural order: café before page, page2 before page10.
    assert_equal [ "Vol%201/caf%C3%A9%203.webp", "Vol%201/Page1.PNG", "Vol%201/page2.png", "Vol%201/page10.png" ], pages.map { |page| page[:href] }
    assert_equal [ 1, 2, 3, 4 ], pages.map { |page| page[:position] }
    assert_equal [ "image/webp", "image/png", "image/png", "image/png" ], pages.map { |page| page[:media_type] }
    first = pages.second
    assert_equal png.bytesize, first[:size_bytes]
    assert_equal 8, first[:compression_method]
    assert_equal format("%08x", Zlib.crc32(png)), first[:crc32]
    assert_match(/\A[0-9a-f]{8}\z/, first[:crc32])
    assert_equal "PK\x03\x04".b, bytes.byteslice(first[:local_header_offset], 4)
    stored = pages.find { |page| page[:href].include?("webp") }
    assert_equal 0, stored[:compression_method]
    assert_equal stored[:size_bytes], stored[:compressed_size]
    assert_equal %i[position href media_type size_bytes compressed_size compression_method local_header_offset crc32].sort, first.keys.sort
  end

  test "hostile names and links are refused" do
    png = fixed_layout_png(width: 2, height: 2)
    [ "../escape.png", "/absolute.png", "pages\\001.png", "C:/drive.png", "pages//001.png", "pages/./001.png", "page\u0001.png" ].each do |name|
      assert_refused fixed_layout_zip({ name => png }), name
    end
    assert_refused fixed_layout_zip({ "link.png" => { data: "/etc/passwd", external: 0o120777 << 16 } }), "symlink"
    assert_refused fixed_layout_zip({ "fifo.png" => { data: "", external: 0o010644 << 16 } }), "special file"
    duplicate = fixed_layout_zip([ [ "same.png", png ], [ "same.png", png ] ])
    assert_refused duplicate, "duplicate"
    assert_refused fixed_layout_zip([ [ "caf\u00e9.png", png ], [ "cafe\u0301.png", png ] ]), "NFC duplicate"
    assert_refused fixed_layout_zip({ "legacy\xE9.png".b => { data: png, flags: 0 } }), "unflagged non-ASCII"
    assert_refused fixed_layout_zip({ "bad\xFF.png".b => png }), "invalid UTF-8"
  end

  test "encryption unsupported compression ZIP64 and alternative names are refused" do
    png = fixed_layout_png(width: 2, height: 2)
    assert_refused fixed_layout_zip({ "001.png" => { data: png, flags: 0x0801 } }), "encrypted"
    assert_refused fixed_layout_zip({ "001.png" => { data: png, flags: 0x0841 } }), "strong encryption"
    assert_refused fixed_layout_zip({ "001.png" => { data: png, method: 12, compressed_size: png.bytesize } }), "bzip2"
    assert_refused fixed_layout_zip({ "001.png" => { data: png, extra: [ 0x0001, 8, 0 ].pack("vvQ<") } }), "zip64 extra"
    assert_refused fixed_layout_zip({ "001.png" => { data: png, extra: [ 0x7075, 5, 1, 0 ].pack("vvCV") } }), "unicode path"
    assert_refused fixed_layout_zip({ "001.png" => { data: png, extra: [ 0x0009, 40 ].pack("vv") } }), "truncated extra"
    assert_refused fixed_layout_zip({ "001.png" => png }, zip64_locator: true), "zip64 locator"
  end

  test "local headers must agree with the directory and entries must not overlap" do
    png = fixed_layout_png(width: 2, height: 2)
    assert_refused fixed_layout_zip({ "001.png" => { data: png, local_name: "002.png" } }), "renamed local entry"
    assert_refused fixed_layout_zip({ "001.png" => { data: png, local_flags: 0x0808 } }), "flags"
    assert_refused fixed_layout_zip({ "001.png" => { data: png, local_crc: 1 } }), "crc"
    descriptor = fixed_layout_zip({ "001.png" => { data: png, flags: 0x0808, local_crc: 0 } })
    assert_refused descriptor, "a data-descriptor entry whose local CRC disagrees with its local sizes"
    bytes = fixed_layout_zip({ "001.png" => png, "002.png" => png })
    directory = bytes.rindex("PK\x01\x02".b)
    overlapping = bytes.dup
    overlapping[directory + 42, 4] = [ 0 ].pack("V")
    assert_refused overlapping, "second entry pointing at the first"
  end

  test "directory bounds and end-record ambiguity are checked before entries" do
    png = fixed_layout_png(width: 2, height: 2)
    good = fixed_layout_zip({ "001.png" => png })
    assert_equal 1, pages_of(good).size
    assert_refused good.byteslice(0, good.bytesize - 5), "truncated"
    assert_refused good + "trailing".b, "data after the end record"
    assert_refused fixed_layout_zip({ "001.png" => png }, entry_count: 2), "count mismatch"
    assert_refused fixed_layout_zip({ "001.png" => png }, directory_size_delta: 1), "size mismatch"
    hidden = [ 0x06054b50, 0, 0, 1, 1, 46, 0, 0 ].pack("VvvvvVVv")
    assert_refused fixed_layout_zip({ "001.png" => png }, comment: hidden), "a second consistent end record inside the comment"
    huge = good.dup
    eocd = huge.rindex("PK\x05\x06".b)
    huge[eocd + 8, 4] = [ 10_001, 10_001 ].pack("vv")
    assert_refused huge, "too many entries"
    big_directory = good.dup
    big_directory[eocd + 12, 4] = [ 3.megabytes ].pack("V")
    assert_refused big_directory, "oversized directory"
    assert_refused "PK\x05\x06".b + ("\x00".b * 18), "empty"
  end

  test "page sizes are bounded from the directory without inflating anything" do
    png = fixed_layout_png(width: 2, height: 2)
    assert_refused fixed_layout_zip({ "001.png" => { data: png, size: 33.megabytes } }), "oversized page"
    assert_refused fixed_layout_zip({ "001.png" => { data: "", method: 0 } }), "empty page"
    assert_refused fixed_layout_zip({ "ComicInfo.xml" => "<ComicInfo/>", "notes.txt" => "no pages" }), "no images"
    assert_refused fixed_layout_zip({ "001.png" => { data: png, method: 0, compressed_size: png.bytesize - 1 } }), "stored size mismatch"
  end
end
