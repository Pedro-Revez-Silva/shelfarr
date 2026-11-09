# frozen_string_literal: true

require "zip"
require "digest"

# Genuine EPUB 3 Media Overlay publications and imported-alignment documents
# for read-along tests.
#
# The narration is test/fixtures/files/read_along_tones.mp3: 16 seconds in
# which cue N (zero-based) is a sine tone of 330 + 110·N Hz from 2N to 2N+1.8
# seconds, followed by 0.2 seconds of silence. It was generated
# deterministically with:
#
#   ffmpeg -f lavfi -i "aevalsrc='if(lt(mod(t\,2)\,1.8)\,0.5*sin(2*PI*(330+110*floor(t/2))*t)\,0)':s=22050:d=16" \
#     -ac 1 -c:a libmp3lame -b:a 48k -fflags +bitexact -flags:a +bitexact -map_metadata -1 \
#     -id3v2_version 0 -write_xing 1 read_along_tones.mp3
#
# so a test can prove that a highlighted cue's text and the served audio at
# that cue's interval correspond (each cue sounds a different pitch).
module ReadAlongFixtures
  TONES = Rails.root.join("test/fixtures/files/read_along_tones.mp3")
  CUE_COUNT = 8
  WORDS = %w[quiet river lantern harbour meadow orchard willow ember].freeze

  def tone_frequency(cue)
    330 + 110 * cue
  end

  def tone_bytes
    File.binread(TONES)
  end

  # Paragraph text for cue N: long enough that a phone page holds about one.
  def cue_sentence(cue, words: 70)
    word = WORDS[cue % WORDS.size]
    "Cue #{cue + 1} sounds the #{word} tone. " + ([ word ] * words).join(" ") + "."
  end

  # The default overlay: cues 0..4 in chapter one, 5..7 in chapter two.
  def default_read_along_cues(words: 70)
    (0...CUE_COUNT).map do |cue|
      { doc: cue < 5 ? "chapter1.xhtml" : "chapter2.xhtml", id: "c#{cue}", text: cue_sentence(cue, words: words),
        clip_begin: format("0:00:%06.3f", cue * 2.0), clip_end: format("0:00:%06.3f", cue * 2.0 + 1.8) }
    end
  end

  # An EPUB 3 with a real Media Overlay. Options produce the variants tests
  # need: an extra narrated-less section (partial coverage), deflated audio,
  # broken overlays, or no overlay at all (for imported alignments).
  def write_read_along_epub(path, cues: default_read_along_cues, overlay: true, extra_section: false,
    audio_stored: true, smil_override: nil, audio_bytes: tone_bytes, extra_entries: {}, title: "The Narrated Garden")
    docs = cues.group_by { |cue| cue[:doc] }
    docs["chapter1.xhtml"] ||= []
    manifest = +'<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    spine = +""
    entries = {}
    docs.keys.sort.each_with_index do |doc, index|
      id = "doc#{index}"
      overlay_attr = overlay ? %( media-overlay="mo#{index}") : ""
      manifest << %(<item id="#{id}" href="#{doc}" media-type="application/xhtml+xml"#{overlay_attr}/>)
      manifest << %(<item id="mo#{index}" href="#{doc.sub(".xhtml", ".smil")}" media-type="application/smil+xml"/>) if overlay
      spine << %(<itemref idref="#{id}"/>)
      paragraphs = docs[doc].map { |cue| %(<p id="#{cue[:id]}">#{cue[:text]}</p>) }.join
      entries["OEBPS/#{doc}"] = %(<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter #{index + 1}</title><link rel="stylesheet" href="style.css" type="text/css"/></head><body><h1 id="h#{index}">Chapter #{index + 1}</h1>#{paragraphs}</body></html>)
      if overlay
        pars = docs[doc].map do |cue|
          %(<par id="par-#{cue[:id]}"><text src="#{doc}##{cue[:id]}"/><audio src="audio/narration.mp3" clipBegin="#{cue[:clip_begin]}" clipEnd="#{cue[:clip_end]}"/></par>)
        end.join
        entries["OEBPS/#{doc.sub(".xhtml", ".smil")}"] = smil_override&.call(doc) ||
          %(<?xml version="1.0" encoding="UTF-8"?><smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0"><body><seq id="seq-#{index}" epub:textref="#{doc}">#{pars}</seq></body></smil>)
      end
    end
    if extra_section
      manifest << '<item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/>'
      spine << '<itemref idref="notes"/>'
      entries["OEBPS/notes.xhtml"] = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Notes</title></head><body><h1>Notes</h1><p id="n1">These notes have no narration.</p></body></html>'
    end
    manifest << '<item id="css" href="style.css" media-type="text/css"/>'
    manifest << '<item id="narration" href="audio/narration.mp3" media-type="audio/mpeg"/>' if overlay
    metadata = overlay ? '<meta property="media:duration">0:00:16.000</meta><meta property="media:active-class">-epub-media-overlay-active</meta>' : ""
    entries = {
      "META-INF/container.xml" => '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      "OEBPS/content.opf" => %(<?xml version="1.0" encoding="UTF-8"?><package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:7c2f0b8e-61b5-4a39-9a3c-1a2b3c4d5e6f</dc:identifier><dc:title>#{title}</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-09T00:00:00Z</meta>#{metadata}</metadata><manifest>#{manifest}</manifest><spine>#{spine}</spine></package>),
      "OEBPS/nav.xhtml" => %(<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol>#{docs.keys.sort.each_with_index.map { |doc, index| %(<li><a href="#{doc}">Chapter #{index + 1}</a></li>) }.join}</ol></nav></body></html>),
      "OEBPS/style.css" => "p { margin: 0 0 1em; }"
    }.merge(entries).merge(extra_entries)
    FileUtils.rm_f(path)
    # Publishing tools write plain ZIP32 EPUBs; rubyzip 3 adds ZIP64 records
    # unless told otherwise, and read-along refuses ZIP64.
    zip64 = Zip.write_zip64_support
    Zip.write_zip64_support = false
    Zip::File.open(path, create: true) do |zip|
      zip.get_output_stream("mimetype", compression_method: Zip::Entry::STORED) { |out| out.write("application/epub+zip") }
      entries.each { |name, content| zip.get_output_stream(name) { |out| out.write(content) } }
      if overlay && audio_bytes
        method = audio_stored ? Zip::Entry::STORED : Zip::Entry::DEFLATED
        zip.get_output_stream("OEBPS/audio/narration.mp3", compression_method: method) { |out| out.write(audio_bytes) }
      end
    end
    path
  ensure
    Zip.write_zip64_support = zip64 unless zip64.nil?
  end

  # A version 1 shelfarr-read-along document for an EPUB without an overlay
  # and a separate single-file audiobook.
  def read_along_document(epub_path:, audio_path:, cues: default_read_along_cues, tool: "fixture aligner 1.0", overrides: {})
    {
      format: "shelfarr-read-along", version: 1, tool: tool,
      ebook: { sha256: Digest::SHA256.file(epub_path).hexdigest },
      audio: [ { filename: File.basename(audio_path), sha256: Digest::SHA256.file(audio_path).hexdigest } ],
      cues: cues.map do |cue|
        { href: "OEBPS/#{cue[:doc]}", fragment: cue[:id], audio: 0,
          begin: Consumer::ReadAlong::Clock.milliseconds(cue[:clip_begin]) / 1000.0,
          end: Consumer::ReadAlong::Clock.milliseconds(cue[:clip_end]) / 1000.0 }
      end
    }.merge(overrides).to_json
  end
end
