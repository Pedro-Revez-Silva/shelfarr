# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_test_helper"

class Kobo::SpanIndexTest < ActiveSupport::TestCase
  include KoboTestHelper

  def index(data = kepub_chapter(2, first: 3))
    Kobo::SpanIndex.new(data)
  end

  def place(locations, data = kepub_chapter(2, first: 3), spine_index: 1)
    index(data).locate({ "href" => "OEBPS/Text/ch2.xhtml", "locations" => locations }, spine_index: spine_index)
  end

  test "the chapter progression lands on the real span containing that share of the body text" do
    # Ten 40-character sentences: kobo.3.1 … kobo.7.2. The first span is read, never assumed to be kobo.1.1.
    assert_equal [ "kobo.3.1", "progression", 0.0 ], place({ "progression" => 0 }).to_h.values_at(:span, :method, :fraction)
    assert_equal "kobo.5.2", place({ "progression" => 0.5 }).span
    assert_in_delta 0.4, place({ "progression" => 0.44 }).fraction, 0.0001, "the span start is what the Kobo opens"
    assert_equal "kobo.7.2", place({ "progression" => 1 }).span
    assert_equal "kobo.3.1", place({}).span
    assert_equal "kobo.3.1", place({ "progression" => 7 }).span, "an out-of-range progression is not trusted"
  end

  test "the web reader's CFI for this same file resolves to the span holding that character" do
    # html > body(/4) > div(/2) > div(/2) > p#p5 is the third paragraph (/6); its first span (/2), text (/1), char 15.
    assert_equal [ "kobo.5.1", "cfi" ], place({ "progression" => 0, "cfi" => "epubcfi(/6/4[c2]!/4/2/2/6[p5]/2/1:15)" }).to_h.values_at(:span, :method)
    assert_equal "kobo.5.2", place({ "cfi" => "epubcfi(/6/4!/4/2/2/6/4/1:0)" }).span
    assert_equal "kobo.4.1", place({ "cfi" => "epubcfi(/6/4!/4/2/2/4)" }).span, "an element step uses its start"
    assert_equal "kobo.6.2", place({ "cfi" => "epubcfi(/6/4!/4/2/2,/8/4/1:3,/8/4/1:9)" }).span, "a range uses its start"
  end

  test "a CFI that does not name this chapter or is malformed falls back to the progression" do
    [ "epubcfi(/6/6!/4/2/2/6/2/1:15)", "epubcfi(/6/4!/4/2/2/99)", "epubcfi(/6/4!/4/2/2/6/2/3/1:0)",
      "epubcfi(/6/4!/4/0)", "epubcfi(/6/4!/4~1.0)", "epubcfi(/6/4!/4/2/2/6^[x/2/1:15)", "not a cfi", 42,
      "epubcfi(/6/4!#{'/2' * 600})" ].each do |cfi|
      assert_equal [ "kobo.6.1", "progression" ], place({ "progression" => 0.6, "cfi" => cfi }).to_h.values_at(:span, :method), cfi.to_s
    end
  end

  test "a fragment that names exactly one element of the chapter is used" do
    assert_equal [ "kobo.6.1", "fragment" ], place({ "fragments" => [ "p6" ], "progression" => 0 }).to_h.values_at(:span, :method)
    assert_equal "progression", place({ "fragments" => [ "missing" ], "progression" => 0 }).method
    assert_equal "progression", place({ "fragments" => [ "page=3" ] }).method
  end

  test "only unique koboSpan ids written in the file are destinations" do
    data = <<~XHTML
      <html xmlns="http://www.w3.org/1999/xhtml"><head><meta id="kobo.7.1"/></head><body>
      <p><span id="kobo.1.1">no class</span><span class="koboSpan" id="kobo.1.1">duplicate non-marker</span>
      <span class="koboSpan" id="kobo.7.1">duplicate head id</span><span class="koboSpan" id="kobo.2.1">dup one</span>
      <span class="koboSpan" id="kobo.2.1">dup two</span><span class="koboSpan" id="kobo.x.1">bad id</span>
      <span class="other koboSpan" id="kobo.9.4">the real one</span></p></body></html>
    XHTML
    assert_equal "kobo.9.4", index(data).locate({ "locations" => { "progression" => 0 } }).span
  end

  test "a chapter without real Kobo spans, an unsafe document or an oversized one is refused with its reason" do
    assert_equal "no_kobo_spans", assert_raises(Kobo::SpanIndex::Unsupported) { index("<html><body><p>Plain EPUB text.</p></body></html>") }.reason
    laughs = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE html [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>
      <html><body><span class="koboSpan" id="kobo.1.1">&c;</span></body></html>
    XML
    assert_equal "unsafe_resource", assert_raises(Kobo::SpanIndex::Unsupported) { index(laughs) }.reason
    external = %(<!DOCTYPE html [<!ENTITY x SYSTEM "file:///etc/passwd">]><html><body><span class="koboSpan" id="kobo.1.1">&x;</span></body></html>)
    assert_equal "unsafe_resource", assert_raises(Kobo::SpanIndex::Unsupported) { index(external) }.reason
    assert_equal "chapter_too_large", assert_raises(Kobo::SpanIndex::Unsupported) { index("<html>#{' ' * Kobo::SpanIndex::MAX_BYTES}</html>") }.reason
    assert_equal "unreadable_resource", assert_raises(Kobo::SpanIndex::Unsupported) { index("") }.reason
    many = "<html><body>#{(Kobo::SpanIndex::MAX_SPANS + 1).times.map { |n| %(<span class="koboSpan" id="kobo.1.#{n}">x</span>) }.join}</body></html>"
    assert_equal "too_many_spans", assert_raises(Kobo::SpanIndex::Unsupported) { index(many) }.reason
  end

  test "an XHTML 1.1 document type without declarations is accepted and head text is not counted" do
    data = kepub_chapter(1).sub("<!DOCTYPE html>", '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">')
    assert_equal "kobo.2.1", index(data).locate({ "locations" => { "progression" => 0.2 } }).span
  end
end
