# frozen_string_literal: true

require "fileutils"
require "zlib"
require_relative "../../lib/fixture_zip"

module Migration
  module Browser
    module ReaderMedia
      Z = Migration::FixtureZip
      CONTAINER = '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="%s" media-type="application/oebps-package+xml"/></rootfiles></container>'
      PAGE_COLORS = [ [ 220, 80, 70 ], [ 70, 160, 90 ], [ 60, 110, 200 ], [ 230, 190, 60 ], [ 150, 80, 180 ], [ 60, 180, 190 ], [ 240, 140, 40 ], [ 120, 120, 120 ], [ 200, 90, 150 ], [ 100, 170, 60 ] ].freeze
      COVER_COLOR = [ 15, 95, 85 ].freeze
      WORDS = %w[lantern harbor quiet ledger copper willow meadow cinder orchard pebble summit thistle beacon hollow amber drift].freeze
      HOSTILE = <<~HTML
        <p id="outside">An outside address must not open from the book: <a href="https://evil.test/away">outside link</a>.</p>
        <p id="inside"><a href="three.xhtml#ending">Jump to the ending</a></p>
        <script>window.top.__bookScriptRan = "script";</script>
        <img src="https://evil.test/track.png" alt="An outside picture" onerror="window.top.__bookScriptRan = 'onerror'"/>
        <p onclick="window.top.__bookScriptRan = 'onclick'">A paragraph with a click handler.</p>
        <form action="https://evil.test/steal"><input name="secret"/></form>
        <iframe src="https://evil.test/frame"></iframe>
      HTML

      module_function

      def png_chunk(type, data)
        [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N")
      end

      def png_header(width:, height:)
        "\x89PNG\r\n\x1a\n".b + png_chunk("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC"))
      end

      def png(width:, height:, color:, bars:)
        bar_width = [ width / (bars * 2 + 1), 1 ].max
        row = (0...width).flat_map { |x| (x / bar_width).odd? && (x / bar_width) <= bars * 2 ? [ 20, 20, 40 ] : color }.pack("C*")
        raw = ("\x00".b + row) * height
        png_header(width: width, height: height) + png_chunk("IDAT", Zlib::Deflate.deflate(raw)) + png_chunk("IEND", "".b)
      end

      def page_color(position)
        PAGE_COLORS[(position - 1) % PAGE_COLORS.size]
      end

      def sentence(chapter, paragraph, index)
        words = Array.new(9) { |offset| WORDS[(chapter * 7 + paragraph * 3 + index + offset) % WORDS.size] }
        "#{words.join(' ').capitalize} in chapter #{chapter}, paragraph #{paragraph}."
      end

      def paragraphs(chapter, count)
        (1..count).map { |paragraph| %(<p id="c#{chapter}p#{paragraph}">#{(1..6).map { |index| sentence(chapter, paragraph, index) }.join(' ')}</p>) }.join("\n")
      end

      def xhtml(title, body)
        %(<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en"><head><title>#{title}</title></head><body>\n#{body}\n</body></html>)
      end

      def epub3(identifier, title, chapters, extra_manifest: "", extra_files: {}, extra_nav: [])
        manifest = chapters.each_with_index.map { |(href, _, _), index| %(<item id="c#{index + 1}" href="#{href}" media-type="application/xhtml+xml"/>) }.join
        spine = chapters.each_index.map { |index| %(<itemref idref="c#{index + 1}"/>) }.join
        nav = (chapters.map { |href, label, _| [ href, label ] } + extra_nav).map { |href, label| %(<li><a href="#{href}">#{label}</a></li>) }.join
        files = [
          { name: "mimetype", data: "application/epub+zip", method: 0 },
          { name: "META-INF/container.xml", data: format(CONTAINER, "OEBPS/content.opf") },
          { name: "OEBPS/content.opf", data: %(<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:#{identifier}</dc:identifier><dc:title>#{title}</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-01T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>#{manifest}#{extra_manifest}</manifest><spine>#{spine}</spine></package>) },
          { name: "OEBPS/nav.xhtml", data: xhtml("Contents", %(<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>#{nav}</ol></nav>)) }
        ]
        chapters.each { |href, label, body| files << { name: "OEBPS/#{href}", data: xhtml(label, body) } }
        extra_files.each { |name, data| files << { name: "OEBPS/#{name}", data: data } }
        Z.build(files)
      end

      def text_epub
        epub3("6a1f0b8e-0c55-4a8f-9a51-2f4b8f1d7c01", "Reader Text Sampler", [
          [ "one.xhtml", "The Lantern Ledger", %(<h1>The Lantern Ledger</h1>\n#{paragraphs(1, 28)}) ],
          [ "two.xhtml", "Harbor Copper", %(<h1>Harbor Copper</h1>\n#{HOSTILE}\n#{paragraphs(2, 24)}) ],
          [ "three.xhtml", "Willow Summit", %(<h1>Willow Summit</h1>\n#{paragraphs(3, 20)}\n<p id="ending">The ending of the sampler.</p>) ]
        ], extra_nav: [ [ "three.xhtml#ending", "The ending" ] ])
      end

      def mixed_epub
        words = ->(text, count) { Array.new(count) { text }.join(" ") }
        picture = png(width: 300, height: 220, color: [ 60, 110, 200 ], bars: 2)
        epub3("7b2a1c9f-1d66-4b9a-8b62-3a5c9a2e8d12", "Reader Mixed Pages", [
          [ "start.xhtml", "Before the picture", %(<h1>Before the picture</h1>\n#{paragraphs(5, 6)}) ],
          [ "picture.xhtml", "Words and a picture", %(<h1>Words and a picture</h1>\n<p>#{words.call('Words around a picture.', 260)}</p>\n<p><img src="one.png" alt="A generated picture"/></p>\n<p>#{words.call('More words follow it.', 260)}</p>) ]
        ], extra_manifest: '<item id="picture-image" href="one.png" media-type="image/png"/>', extra_files: { "one.png" => picture })
      end

      def manga_epub(pages: 12, width: 330, height: 500)
        images = (1..pages).to_h { |position| [ "index-#{position}_1.png", png(width: width, height: height, color: page_color(position), bars: 1) ] }
        manifest = images.keys.each_with_index.map { |name, index| %(<item id="img#{index + 1}" href="#{name}" media-type="image/png"/>) }.join
        figures = (1..pages).map { |position| %(<p class="calibre1"><a id="p#{position}"></a><img src="index-#{position}_1.png" alt="Image #{position}" class="calibre2"/></p>) }.join("\n")
        files = [
          { name: "mimetype", data: "application/epub+zip", method: 0 },
          { name: "META-INF/container.xml", data: format(CONTAINER, "content.opf") },
          { name: "content.opf", data: %(<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uuid_id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf"><dc:title>Reader Harbor Sketches</dc:title><dc:identifier id="uuid_id" opf:scheme="uuid">8c3b2d0a-2e77-4cab-9c73-4b6dab3f9e23</dc:identifier><dc:language>en</dc:language><meta name="cover" content="cover"/></metadata>) +
            %(<manifest><item id="cover" href="cover.png" media-type="image/png"/><item id="titlepage" href="titlepage.xhtml" media-type="application/xhtml+xml"/><item id="id1" href="index.html" media-type="application/xhtml+xml"/>) +
            %(<item id="css" href="stylesheet.css" media-type="text/css"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>#{manifest}</manifest><spine toc="ncx"><itemref idref="titlepage"/><itemref idref="id1"/></spine></package>) },
          { name: "toc.ncx", data: '<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="8c3b2d0a-2e77-4cab-9c73-4b6dab3f9e23"/></head><docTitle><text>Reader Harbor Sketches</text></docTitle><navMap><navPoint id="start" playOrder="1"><navLabel><text>Start</text></navLabel><content src="titlepage.xhtml"/></navPoint><navPoint id="pages" playOrder="2"><navLabel><text>Pages</text></navLabel><content src="index.html"/></navPoint></navMap></ncx>' },
          { name: "titlepage.xhtml", data: %(<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en"><head><title>Cover</title><style type="text/css">body { text-align: center; padding: 0; margin: 0; }</style></head><body><div><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" width="100%" height="100%" viewBox="0 0 #{width} #{height}" preserveAspectRatio="none"><image width="#{width}" height="#{height}" xlink:href="cover.png"/></svg></div></body></html>) },
          { name: "index.html", data: %(<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml" lang="" xml:lang=""><head><title>index</title><link rel="stylesheet" type="text/css" href="stylesheet.css"/></head>\n<body class="calibre">\n#{figures}\n</body></html>) },
          { name: "stylesheet.css", data: ".calibre { display: block; margin: 0 5pt } .calibre1 { display: block; margin: 1em 0 } .calibre2 { height: auto; width: auto }" },
          { name: "cover.png", data: png(width: width, height: height, color: COVER_COLOR, bars: 0) }
        ] + images.map { |name, data| { name: name, data: data } }
        Z.build(files)
      end

      COMIC_PAGES = [ "página 10.png", "página 2.png", "日本/終.png", "página 1.png", "página 3.png" ].freeze
      COMIC_ORDER = [ "página 1.png", "página 2.png", "página 3.png", "página 10.png", "日本/終.png" ].freeze
      PDF_SIZE = [ 360, 540 ].freeze

      def pdf_document(pages:)
        width, height = PDF_SIZE
        objects = { 1 => "<< /Type /Catalog /Pages 2 0 R >>", 3 => "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>" }
        kids = []
        (1..pages).each do |position|
          red, green, blue = page_color(position).map { |value| format("%.4f", value / 255.0) }
          bars = (1..position).map { |bar| "0.08 0.08 0.16 rg #{bar * 24} 40 12 60 re f" }.join("\n")
          stream = "#{red} #{green} #{blue} rg 0 0 #{width} #{height} re f\n1 1 1 rg 30 #{height - 150} #{width - 60} 110 re f\n#{bars}\nBT 0 0 0 rg /F1 30 Tf 48 #{height - 105} Td (Page #{position} of #{pages}) Tj ET"
          page, content = 4 + (position - 1) * 2, 5 + (position - 1) * 2
          objects[page] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{width} #{height}] /Resources << /Font << /F1 3 0 R >> >> /Contents #{content} 0 R >>"
          objects[content] = "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
          kids << "#{page} 0 R"
        end
        objects[2] = "<< /Type /Pages /Kids [#{kids.join(' ')}] /Count #{pages} >>"
        body = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
        offsets = {}
        objects.keys.sort.each do |number|
          offsets[number] = body.bytesize
          body << "#{number} 0 obj\n#{objects[number]}\nendobj\n".b
        end
        xref = body.bytesize
        body << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n".b
        objects.keys.sort.each { |number| body << format("%010d 00000 n \n", offsets[number]).b }
        body << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n".b
      end

      def comic_page(position)
        png(width: 330, height: 500, color: page_color(position), bars: position)
      end

      def comic_cbz
        Z.build(COMIC_PAGES.map { |name| Z.page(name, comic_page(COMIC_ORDER.index(name) + 1)) } + [ Z.page("ComicInfo.xml", "<ComicInfo/>") ])
      end

      def damaged_cbz
        oversized = png_header(width: 20_000, height: 20_000)
        Z.build([
          Z.page("01.png", comic_page(1)),
          Z.page("02.png", comic_page(2), central: { crc: 1 }, local: { crc: 1 }),
          Z.page("03.png", oversized + "\x00".b * 64),
          Z.page("04.png", comic_page(4))
        ])
      end

      def silent_wav(seconds, rate: 8000)
        data = "\x00\x00".b * (seconds * rate)
        "RIFF".b + [ 36 + data.bytesize ].pack("V") + "WAVE".b + "fmt ".b + [ 16, 1, 1, rate, rate * 2, 2, 16 ].pack("VvvVVvv") + "data".b + [ data.bytesize ].pack("V") + data
      end
    end
  end
end
