# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/read_along_fixtures"

class Consumer::ReadAlongTest < ActiveSupport::TestCase
  include ConsumerTestHelper
  include ReadAlongFixtures

  setup do
    prepare_consumer_library
    Consumer::ReadAlong.forget_all
    write_read_along_epub(@epub_path)
  end
  teardown { FileUtils.remove_entry(@root) if @root && File.exist?(@root) }

  def status_for(book = @ebook)
    asset = Consumer::LibraryAssets.new(book).list.first
    Consumer::ReadAlong.for(book, asset)
  end

  def write_overlay(**options)
    Consumer::ReadAlong.forget_all
    write_read_along_epub(@epub_path, **options)
  end

  test "a genuine media overlay becomes a manifest of real cues bound to the asset generation" do
    status = status_for
    assert_equal "available", status.status
    assert_equal "media_overlay", status.source
    core = status.core
    assert_equal %w[OEBPS/chapter1.xhtml OEBPS/chapter2.xhtml], core[:text].map { |text| text[:href] }
    assert_equal [ { kind: "epub_resource", href: "OEBPS/audio/narration.mp3", media_type: "audio/mpeg", size_bytes: File.size(TONES) } ], core[:audio]
    assert_equal Consumer::ReadAlong::CUE_FIELDS, core[:cue_fields]
    assert_equal (0...8).map { |cue| [ cue < 5 ? 0 : 1, "c#{cue}", 0, cue * 2000, cue * 2000 + 1800 ] }, core[:cues]
    assert_equal({ complete: true, text_sections: 2, aligned_sections: 2, unaligned_sections: [], cues: 8, audio_ms: 14_400 }, core[:coverage])
    hrefs = core[:resources].map { |resource| resource[:href] }
    assert_includes hrefs, "META-INF/container.xml"
    assert_includes hrefs, "OEBPS/content.opf"
    assert_includes hrefs, "OEBPS/style.css"
    assert_not_includes hrefs, "OEBPS/audio/narration.mp3"
    assert_not_includes hrefs, "OEBPS/chapter1.smil"
    asset = Consumer::LibraryAssets.new(@ebook).list.first
    assert_equal Digest::SHA256.hexdigest([ "media_overlay", 1, asset.id ].join("\0")), status.generation
  end

  test "partial coverage names the narrated-less sections instead of hiding them" do
    write_overlay(extra_section: true)
    coverage = status_for.core[:coverage]
    assert_not coverage[:complete]
    assert_equal [ 3, 2 ], coverage.values_at(:text_sections, :aligned_sections)
    assert_equal [ "OEBPS/notes.xhtml" ], coverage[:unaligned_sections]
  end

  test "an EPUB without any alignment is unaligned and names a same-work audiobook honestly" do
    write_consumer_epub(@epub_path.tap { |path| File.unlink(path) })
    @ebook.update!(open_library_work_id: "OL1W")
    @audiobook.update!(open_library_work_id: "OL1W")
    status = status_for
    assert_equal "unaligned", status.status
    assert_nil status.core
    assert_equal({ id: @audiobook.id.to_s, title: @audiobook.title }, status.audiobook)
  end

  test "invalid intervals, overlaps, missing targets and foreign resources refuse the whole overlay" do
    cues = default_read_along_cues
    {
      "end before begin" => cues.each_with_index.map { |cue, index| index == 2 ? cue.merge(clip_end: "0:00:03.000") : cue },
      "overlap" => cues.each_with_index.map { |cue, index| index == 3 ? cue.merge(clip_begin: "0:00:05.000") : cue },
      "bad clock" => cues.each_with_index.map { |cue, index| index == 1 ? cue.merge(clip_begin: "1:99:00") : cue },
      "beyond 48 hours" => cues.each_with_index.map { |cue, index| index == 7 ? cue.merge(clip_end: "49:00:00") : cue }
    }.each do |label, variant|
      write_overlay(cues: variant)
      status = status_for
      assert_equal "invalid", status.status, label
      assert_nil status.core, label
      assert_match(/narration data can't be used/, status.reason, label)
    end

    write_overlay(smil_override: ->(doc) { %(<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><par><text src="#{doc}#missing"/><audio src="audio/narration.mp3" clipBegin="0s" clipEnd="1s"/></par></body></smil>) })
    assert_match(/isn't in this book/, status_for.reason)
    write_overlay(smil_override: ->(doc) { %(<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><par><text src="#{doc}#c0"/><audio src="../../outside.mp3" clipBegin="0s" clipEnd="1s"/></par></body></smil>) })
    assert_equal "invalid", status_for.status
    write_overlay(smil_override: ->(doc) { %(<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><par><text src="#{doc}#c0"/><audio src="https://example.invalid/a.mp3" clipBegin="0s" clipEnd="1s"/></par></body></smil>) })
    assert_equal "invalid", status_for.status
    write_overlay(smil_override: ->(doc) { %(<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><par><text src="#{doc}#c0"/><audio src="style.css" clipBegin="0s" clipEnd="1s"/></par></body></smil>) })
    assert_equal "invalid", status_for.status
  end

  test "entity declarations and external entities are refused before parsing" do
    write_overlay(smil_override: ->(doc) { %(<?xml version="1.0"?><!DOCTYPE smil [<!ENTITY x SYSTEM "file:///etc/passwd">]><smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><par><text src="#{doc}#c0"/><audio src="audio/narration.mp3" clipBegin="0s" clipEnd="&x;"/></par></body></smil>) })
    status = status_for
    assert_equal "invalid", status.status
    assert_no_match(/root:/, status.reason.to_s)
  end

  test "SMIL clock values follow the SMIL 3 grammar" do
    clock = Consumer::ReadAlong::Clock
    assert_equal 3_723_500, clock.milliseconds("1:02:03.5")
    assert_equal 123_456, clock.milliseconds("02:03.456")
    assert_equal 3500, clock.milliseconds("3.5")
    assert_equal 3500, clock.milliseconds("3.5s")
    assert_equal 250, clock.milliseconds("250ms")
    assert_equal 120_000, clock.milliseconds("2min")
    assert_equal 5_400_000, clock.milliseconds("1.5h")
    assert_equal 1, clock.milliseconds("0.0005s")
    [ "", "-1s", "1:60:00", "61:00", "3.5sec", "abc", "1e3", "49h" ].each do |value|
      assert_raises(clock::Invalid, value) { clock.milliseconds(value) }
    end
  end

  test "a ZIP entry streams exactly its bytes, stored or deflated, without exceeding its size" do
    write_overlay(audio_stored: false)
    File.open(@epub_path, "rb") do |file|
      package = Consumer::EpubPackage.open(file)
      assert_equal Consumer::ZipDirectory::DEFLATED, package.entry("OEBPS/audio/narration.mp3").method
      bytes = +""
      package.stream("OEBPS/audio/narration.mp3", 40_000, 40_999) { |chunk| bytes << chunk }
      assert_equal tone_bytes.byteslice(40_000, 1000), bytes
      assert_equal tone_bytes, package.read("OEBPS/audio/narration.mp3", limit: 1.megabyte)
      assert_raises(Consumer::EpubPackage::Invalid) { package.read("OEBPS/audio/narration.mp3", limit: 10) }
      assert_raises(Consumer::EpubPackage::Invalid) { package.stream("OEBPS/audio/narration.mp3", 0, tone_bytes.bytesize) { nil } }
    end
  end

  test "a deflated entry that inflates beyond its announced size is refused" do
    data = "A" * 200_000
    deflated = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS).then { |z| z.deflate(data, Zlib::FINISH) }
    name = "bomb.bin"
    local = [ 0x04034b50, 20, 0, 8, 0, 0, Zlib.crc32(data), deflated.bytesize, 100, name.bytesize, 0 ].pack("VvvvvvVVVvv") + name + deflated
    central = [ 0x02014b50, 20, 20, 0, 8, 0, 0, Zlib.crc32(data), deflated.bytesize, 100, name.bytesize, 0, 0, 0, 0, 0, 0 ].pack("VvvvvvvVVVvvvvvVV") + name
    eocd = [ 0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0 ].pack("VvvvvVVv")
    path = File.join(@root, "bomb.zip")
    File.binwrite(path, local + central + eocd)
    File.open(path, "rb") do |file|
      zip = Consumer::ZipDirectory.new(file)
      entry = zip.entries.first
      assert_raises(Consumer::ZipDirectory::Invalid) { zip.read_entry(entry, limit: 1.megabyte) }
      assert_raises(Consumer::ZipDirectory::Invalid) { zip.stream_entry(entry, 0, 99) { nil } }
    end
  end

  test "paths stay inside the archive and only manifest items are servable" do
    File.open(@epub_path, "rb") do |file|
      package = Consumer::EpubPackage.open(file)
      assert_equal "OEBPS/chapter1.xhtml", package.resolve("chapter1.xhtml", from: "OEBPS/chapter1.smil")
      assert_equal [ "OEBPS/chapter 1.xhtml", "p 1" ], package.resolve("chapter%201.xhtml#p%201", from: "OEBPS/content.opf", fragment: true)
      assert_nil package.resolve("https://example.invalid/x.xhtml", from: "OEBPS/content.opf")
      assert_raises(Consumer::EpubPackage::Invalid) { package.resolve("../../x", from: "OEBPS/content.opf") }
      assert_raises(Consumer::EpubPackage::Invalid) { package.resolve("/etc/passwd", from: "OEBPS/content.opf") }
      assert package.servable?("OEBPS/chapter1.xhtml")
      assert package.servable?("META-INF/container.xml")
      assert_not package.servable?("mimetype")
      assert_not package.servable?("OEBPS/../mimetype")
    end
  end

  test "an imported alignment binds both files by digest and becomes stale when either generation changes" do
    write_consumer_epub(@epub_path.tap { |path| File.unlink(path) })
    write_read_along_epub(@epub_path, overlay: false)
    FileUtils.cp(TONES, @audio_path)
    document = read_along_document(epub_path: @epub_path, audio_path: @audio_path)
    alignment = Consumer::ReadAlong::Import.new(ebook: @ebook, audiobook: @audiobook, user: users(:one)).call(document)
    assert_equal 8, alignment.cue_count
    status = status_for
    assert_equal "available", status.status
    assert_equal "imported", status.source
    audio_asset = Consumer::LibraryAssets.new(@audiobook).list.first
    assert_equal [ { kind: "publication_asset", publication_id: @audiobook.id.to_s, asset_id: audio_asset.id,
      filename: File.basename(@audio_path), media_type: "audio/mpeg", size_bytes: File.size(TONES) } ], status.core[:audio]
    assert_equal [ 0, "c0", 0, 0, 1800 ], status.core[:cues].first

    # Same bytes, new generation (the file was rewritten in place): stale
    # until recheck proves the digest is unchanged.
    FileUtils.cp(TONES, "#{@audio_path}.new")
    File.rename("#{@audio_path}.new", @audio_path)
    Consumer::ReadAlong.forget_all
    stale = status_for
    assert_equal "stale", stale.status
    assert_match(/audiobook files changed/, stale.reason)
    Consumer::ReadAlong::Import.recheck(alignment.reload)
    assert_equal "available", status_for.status
    old_generation = status.generation
    assert_not_equal old_generation, status_for.generation

    # Different bytes: recheck refuses to rebind.
    File.binwrite(@audio_path, tone_bytes.reverse)
    Consumer::ReadAlong.forget_all
    assert_equal "stale", status_for.status
    assert_raises(Consumer::ReadAlong::Import::Invalid) { Consumer::ReadAlong::Import.recheck(alignment.reload) }

    # A changed EPUB is stale too.
    File.binwrite(@audio_path, tone_bytes)
    Consumer::ReadAlong::Import.recheck(alignment.reload)
    write_read_along_epub(@epub_path, overlay: false, title: "A different edition")
    Consumer::ReadAlong.forget_all
    assert_equal "stale", status_for.status
    assert_match(/EPUB changed/, status_for.reason)
  end

  test "imports are refused unless every digest, track, target and interval is real" do
    write_consumer_epub(@epub_path.tap { |path| File.unlink(path) })
    write_read_along_epub(@epub_path, overlay: false)
    FileUtils.cp(TONES, @audio_path)
    import = Consumer::ReadAlong::Import.new(ebook: @ebook, audiobook: @audiobook)
    base = JSON.parse(read_along_document(epub_path: @epub_path, audio_path: @audio_path))
    variants = {
      "wrong format" => base.merge("format" => "other"),
      "unknown key" => base.merge("timing" => "estimated"),
      "ebook digest" => base.merge("ebook" => { "sha256" => "0" * 64 }),
      "audio digest" => base.merge("audio" => [ base["audio"][0].merge("sha256" => "1" * 64) ]),
      "unknown track" => base.merge("audio" => [ base["audio"][0].merge("filename" => "other.mp3") ]),
      "missing fragment" => base.merge("cues" => [ base["cues"][0].merge("fragment" => "nowhere") ]),
      "non-spine text" => base.merge("cues" => [ base["cues"][0].merge("href" => "OEBPS/style.css") ]),
      "outside path" => base.merge("cues" => [ base["cues"][0].merge("href" => "../chapter1.xhtml") ]),
      "negative time" => base.merge("cues" => [ base["cues"][0].merge("begin" => -1) ]),
      "empty interval" => base.merge("cues" => [ base["cues"][0].merge("end" => 0) ]),
      "string time" => base.merge("cues" => [ base["cues"][0].merge("begin" => "0.0") ]),
      "overlap" => base.merge("cues" => [ base["cues"][0], base["cues"][1].merge("begin" => 1.0) ]),
      "audio index" => base.merge("cues" => [ base["cues"][0].merge("audio" => 1) ]),
      "no cues" => base.merge("cues" => [])
    }
    variants.each do |label, document|
      assert_raises(Consumer::ReadAlong::Import::Invalid, label) { import.call(document.to_json) }
    end
    assert_raises(Consumer::ReadAlong::Import::Invalid) { import.call("{") }
    assert_raises(Consumer::ReadAlong::Import::Invalid) { Consumer::ReadAlong::Import.new(ebook: @audiobook, audiobook: @ebook).call(base.to_json) }
    assert_equal 0, ReadAlongAlignment.count
  end
end
