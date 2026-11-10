# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_test_helper"

class Kobo::KepubConverterTest < ActiveSupport::TestCase
  include KoboTestHelper

  CHAPTER = "OEBPS/Text/ch2.xhtml"

  setup { @dir = Dir.mktmpdir("kepub-converter") }
  teardown { FileUtils.remove_entry(@dir) }

  def epub(chapters: {}, extra: {})
    path = File.join(@dir, "#{SecureRandom.hex(4)}.epub")
    write_plain_epub(path, chapters: chapters)
    unless extra.empty?
      Zip::File.open(path) { |zip| extra.each { |name, data| zip.get_output_stream(name) { |out| out.write(data) } } }
    end
    path
  end

  def convert(path, limit: 50.megabytes)
    output = File.join(@dir, "#{SecureRandom.hex(4)}.kepub.epub")
    File.open(path, "rb") do |source|
      File.open(output, "wb") { |io| @result = Kobo::KepubConverter.new(source).write(io, limit: limit) }
    end
    output
  end

  def reason(path)
    assert_raises(Kobo::KepubConverter::Unsupported) { convert(path) }.reason
  end

  # Rewrites bytes in both the local and central headers of a built ZIP.
  def patch(path, from, to)
    data = File.binread(path)
    assert_equal from.bytesize, to.bytesize
    File.binwrite(path, data.gsub(from, to))
  end

  test "the same source always produces the same verified copy" do
    path = epub
    first, second = 2.times.map { travel(2.seconds) { Digest::SHA256.file(convert(path)).hexdigest } }
    assert_equal first, second
    File.open(path, "rb") do |source|
      File.open(convert(path), "rb") { |copy| assert_equal @result.spans, Kobo::KepubConverter.verify(source, copy, chapters: @result.chapters) }
    end
    assert_equal [ "OEBPS/Text/chapter 1.xhtml", CHAPTER, "OEBPS/Text/ch3.xhtml" ], @result.chapters
  end

  test "verification rejects a copy whose text differs from its source" do
    path = epub
    tampered = epub(chapters: { CHAPTER => plain_chapter(2).sub("begins here", "begins there") })
    File.open(path, "rb") do |source|
      File.open(convert(tampered), "rb") do |copy|
        assert_equal "verification_failed", assert_raises(Kobo::KepubConverter::Unsupported) {
          Kobo::KepubConverter.verify(source, copy, chapters: @result.chapters)
        }.reason
      end
    end
  end

  test "document type declarations are refused, so no entity is ever expanded or fetched" do
    xxe = <<~XHTML
      <?xml version="1.0"?>
      <!DOCTYPE html [ <!ENTITY secret SYSTEM "file:///etc/passwd"> <!ENTITY a "aaaaaaaaaa"> <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;"> ]>
      <html xmlns="http://www.w3.org/1999/xhtml"><body><p>&secret; &b;</p></body></html>
    XHTML
    assert_equal "unsafe_resource", reason(epub(chapters: { CHAPTER => xxe }))
  end

  test "malformed, foreign and already converted chapters keep the book a plain EPUB" do
    assert_equal "not_well_formed", reason(epub(chapters: { CHAPTER => "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>Open</body></html>" }))
    assert_equal "not_well_formed", reason(epub(chapters: { CHAPTER => "<!DOCTYPE html><html xmlns='http://www.w3.org/1999/xhtml'><body><p>a&nbsp;b</p></body></html>" }))
    assert_equal "not_xhtml", reason(epub(chapters: { CHAPTER => "<svg xmlns='http://www.w3.org/2000/svg'><body/></svg>" }))
    assert_equal "already_kobo_markup", reason(epub(chapters: { CHAPTER => kepub_chapter(2) }))
    assert_equal "already_kobo_markup", reason(epub(chapters: { CHAPTER => plain_chapter(2).sub('id="c2p1"', 'id="kobo.1.1"') }))
  end

  test "chapter, span, inflation and output limits are enforced" do
    huge = "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>#{'x' * (Kobo::KepubConverter::MAX_CHAPTER_BYTES + 1)}</p></body></html>"
    assert_equal "chapter_too_large", reason(epub(chapters: { CHAPTER => huge }))
    # Small enough to read, but the added markers would pass the read limit.
    near = "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>#{'Go. ' * 1_000_000}</p></body></html>"
    assert_includes %w[too_many_spans chapter_too_large], reason(epub(chapters: { CHAPTER => near }))
    many = "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>#{'a. ' * (Kobo::SpanIndex::MAX_SPANS + 1)}</p></body></html>"
    assert_equal "too_many_spans", reason(epub(chapters: { CHAPTER => many }))

    bomb = epub(extra: { "OEBPS/Images/big.png" => "\0" * 1000 })
    # Declare far more inflated bytes than the bound in the central directory.
    data = File.binread(bomb)
    offset = data.rindex("PK\x01\x02".b) # the central header of the entry added last
    data[offset + 24, 4] = [ Kobo::KepubConverter::MAX_INFLATED_BYTES + 1 ].pack("V")
    File.binwrite(bomb, data)
    assert_equal "too_large", reason(bomb)

    assert_raises(Kobo::KepubConverter::LimitExceeded) { convert(epub, limit: 2_000) }
  end

  test "protected, unsafe and duplicate entries are refused" do
    assert_equal "protected", reason(epub(extra: { "META-INF/rights.xml" => "<rights/>" }))
    assert_equal "unsafe_entry", reason(epub(extra: { "OEBPS/../../evil.txt" => "x" }))

    duplicate = epub(extra: { "OEBPS/Images/aaa.png" => "first", "OEBPS/Images/bbb.png" => "second" })
    patch(duplicate, "OEBPS/Images/bbb.png", "OEBPS/Images/aaa.png")
    assert_equal "duplicate_entries", reason(duplicate)

    # A Unix symlink entry: its central header's external attributes say so.
    symlink = epub(extra: { "OEBPS/Images/link.png" => "/etc/passwd" })
    data = File.binread(symlink)
    offset = data.rindex("PK\x01\x02".b)
    assert_equal "OEBPS/Images/link.png", data[offset + 46, 21]
    data[offset + 5] = [ Zip::FSTYPE_UNIX ].pack("C")
    data[offset + 38, 4] = [ 0o120777 << 16 ].pack("V")
    File.binwrite(symlink, data)
    assert_equal "unsafe_entry", reason(symlink)
  end

  test "spine documents that are not XHTML and every other entry are copied byte for byte" do
    path = epub(extra: { "OEBPS/Images/cover.svg" => "<svg xmlns='http://www.w3.org/2000/svg'/>", "OEBPS/Fonts/f.otf" => "font\0bytes" })
    source = zip_entries(path)
    copy = zip_entries(convert(path))
    (source.keys - @result.chapters).each { |name| assert_equal source[name], copy[name], name }
    assert_equal source.keys, copy.keys
  end
end
