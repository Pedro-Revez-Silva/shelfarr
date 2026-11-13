# frozen_string_literal: true

require "zlib"

# Generated PDFs, page images and ZIP archives for fixed-layout tests. ZIPs are
# assembled byte by byte so tests can describe exactly the malformed or hostile
# structures a reader must refuse.
module FixedLayoutFixtures
  ZipEntry = Struct.new(:name, :data, :method, :flags, :made_by, :external, :extra, :local_name, :local_flags,
    :local_crc, :crc, :compressed_size, :size, :offset, keyword_init: true)

  # A real multi-page PDF using the standard Helvetica font, so a renderer
  # also needs its bundled standard-font data.
  def fixed_layout_pdf(pages: 3, width: 400, height: 560, label: "Page")
    objects = []
    objects << "<< /Type /Catalog /Pages 2 0 R >>"
    kids = (0...pages).map { |index| "#{4 + index * 2} 0 R" }.join(" ")
    objects << "<< /Type /Pages /Kids [#{kids}] /Count #{pages} >>"
    objects << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    pages.times do |index|
      shade = (0.55 + 0.4 * index / [ pages - 1, 1 ].max).round(3)
      stream = "#{shade} 0.85 0.95 rg 0 0 #{width} #{height} re f 0.1 0.1 0.2 rg BT /F1 36 Tf 48 #{height - 120} Td (#{label} #{index + 1}) Tj ET " \
        "BT /F1 14 Tf 48 #{height - 160} Td (Selectable words on page #{index + 1} of #{pages}.) Tj ET"
      objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{width} #{height}] /Resources << /Font << /F1 3 0 R >> >> /Contents #{5 + index * 2} 0 R >>"
      objects << "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
    end
    body = +"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n".b
    offsets = objects.each_with_index.map do |object, index|
      offset = body.bytesize
      body << "#{index + 1} 0 obj\n#{object}\nendobj\n".b
      offset
    end
    xref = body.bytesize
    body << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n".b
    offsets.each { |offset| body << format("%010d 00000 n \n", offset).b }
    body << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n".b
    body
  end

  # An opaque PNG of one colour with `bars` dark vertical bars, so tests can
  # tell pages apart by their pixels.
  def fixed_layout_png(width: 300, height: 420, color: [ 200, 120, 60 ], bars: 1)
    bar_width = [ width / (bars * 2 + 1), 1 ].max
    row = (0...width).map do |x|
      band = x / bar_width
      band.odd? && band <= bars * 2 ? [ 20, 20, 40 ] : color
    end.flatten.pack("C*")
    raw = ("\x00".b + row) * height
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(raw)) + chunk.call("IEND", "".b)
  end

  # Ten distinct colours, cycled for page N (one-based).
  def fixed_layout_page_color(position)
    [ [ 220, 80, 70 ], [ 70, 160, 90 ], [ 60, 110, 200 ], [ 230, 190, 60 ], [ 150, 80, 180 ],
      [ 60, 180, 190 ], [ 240, 140, 40 ], [ 120, 120, 120 ], [ 200, 90, 150 ], [ 100, 170, 60 ] ][(position - 1) % 10]
  end

  IMAGE_EPUB_COVER_COLOR = [ 15, 95, 85 ].freeze

  # A reflowable, image-only EPUB shaped like a calibre conversion of a manga
  # volume: an EPUB 2 package with an NCX table of contents only, a title page
  # whose cover is an SVG <image xlink:href>, and one index.html holding every
  # page as <p><a id/><img/></p>. No fixed-layout metadata, no viewport. Page N
  # is one colour (fixed_layout_page_color) with a dark bar down its middle.
  def image_only_epub(pages:, width: 330, height: 500)
    images = (1..pages).to_h { |position| [ "index-#{position}_1.png", fixed_layout_png(width: width, height: height, color: fixed_layout_page_color(position), bars: 1) ] }
    manifest = images.keys.each_with_index.map { |name, index| %(<item id="img#{index + 1}" href="#{name}" media-type="image/png"/>) }.join
    paragraphs = (1..pages).map { |position| %(<p class="calibre1"><a id="p#{position}"></a><img src="index-#{position}_1.png" alt="Image #{position}" class="calibre2"/></p>) }.join("\n")
    fixed_layout_zip({
      "mimetype" => { data: "application/epub+zip", method: 0 },
      "META-INF/container.xml" => '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      "content.opf" => %(<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uuid_id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf"><dc:title>Harbor Sketches</dc:title><dc:identifier id="uuid_id" opf:scheme="uuid">2f6d1c1e-8a4b-4c55-9d1a-0b8f3e7c6a21</dc:identifier><dc:language>en</dc:language><meta name="cover" content="cover"/></metadata>) +
        %(<manifest><item id="cover" href="cover.png" media-type="image/png"/><item id="titlepage" href="titlepage.xhtml" media-type="application/xhtml+xml"/><item id="id1" href="index.html" media-type="application/xhtml+xml"/>) +
        %(<item id="css" href="stylesheet.css" media-type="text/css"/><item id="page_css" href="page_styles.css" media-type="text/css"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>#{manifest}</manifest>) +
        %(<spine toc="ncx"><itemref idref="titlepage"/><itemref idref="id1"/></spine><guide><reference type="cover" href="titlepage.xhtml" title="Cover"/></guide></package>),
      "toc.ncx" => '<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="2f6d1c1e-8a4b-4c55-9d1a-0b8f3e7c6a21"/></head><docTitle><text>Harbor Sketches</text></docTitle><navMap><navPoint id="start" playOrder="1"><navLabel><text>Start</text></navLabel><content src="titlepage.xhtml"/></navPoint></navMap></ncx>',
      "titlepage.xhtml" => %(<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en"><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/><meta name="calibre:cover" content="true"/><title>Cover</title><style type="text/css">@page {padding: 0pt; margin:0pt} body { text-align: center; padding:0pt; margin: 0pt; }</style></head>) +
        %(<body><div><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" width="100%" height="100%" viewBox="0 0 #{width} #{height}" preserveAspectRatio="none"><image width="#{width}" height="#{height}" xlink:href="cover.png"/></svg></div></body></html>),
      "index.html" => %(<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml" lang="" xml:lang=""><head><title>index</title><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><link rel="stylesheet" type="text/css" href="stylesheet.css"/><link rel="stylesheet" type="text/css" href="page_styles.css"/></head>\n<body class="calibre">\n#{paragraphs}\n</body></html>),
      "stylesheet.css" => ".calibre { display: block; font-size: 1em; padding-left: 0; padding-right: 0; margin: 0 5pt } .calibre1 { display: block; margin: 1em 0 } .calibre2 { height: auto; width: auto }",
      "page_styles.css" => "@page { margin-bottom: 5pt; margin-top: 5pt }",
      "cover.png" => fixed_layout_png(width: width, height: height, color: IMAGE_EPUB_COVER_COLOR, bars: 0)
    }.merge(images))
  end

  def comic_pages(count, width: 300, height: 420)
    (1..count).to_h { |position| [ format("pages/%03d.png", position), fixed_layout_png(width: width, height: height, color: fixed_layout_page_color(position), bars: position) ] }
  end

  # entries: { name => bytes } or ZipEntry-like hashes. Options shape the
  # directory: :comment, :zip64_locator, :prefix, :extra_eocd.
  def fixed_layout_zip(entries, comment: "", zip64_locator: false, prefix: "".b, trailing_eocd: nil, entry_count: nil, directory_size_delta: 0)
    list = entries.map do |name, data|
      data.is_a?(Hash) ? ZipEntry.new(name: name, method: 8, flags: 0x0800, made_by: 0x0314, external: 0o100644 << 16, extra: "".b, **data) :
        ZipEntry.new(name: name, data: data, method: 8, flags: 0x0800, made_by: 0x0314, external: 0o100644 << 16, extra: "".b)
    end
    body = prefix.b.dup
    list.each do |entry|
      data = entry.data.to_s.b
      compressed = entry.method == 8 ? Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS).then { |z| z.deflate(data, Zlib::FINISH).tap { z.close } } : data
      entry.crc ||= Zlib.crc32(data)
      entry.compressed_size ||= compressed.bytesize
      entry.size ||= data.bytesize
      entry.offset = body.bytesize
      name = (entry.local_name || entry.name).b
      body << [ 0x04034b50, 20, entry.local_flags || entry.flags, entry.method, 0, 0x5b21, entry.local_crc || entry.crc,
        entry.compressed_size, entry.size, name.bytesize, entry.extra.bytesize ].pack("VvvvvvVVVvv") << name << entry.extra << compressed
    end
    directory_offset = body.bytesize
    list.each do |entry|
      body << [ 0x02014b50, entry.made_by, 20, entry.flags, entry.method, 0, 0x5b21, entry.crc, entry.compressed_size,
        entry.size, entry.name.b.bytesize, entry.extra.bytesize, 0, 0, 0, entry.external, entry.offset ].pack("VvvvvvvVVVvvvvvVV") <<
        entry.name.b << entry.extra
    end
    directory_size = body.bytesize - directory_offset + directory_size_delta
    if zip64_locator
      body << [ 0x07064b50, 0, 0, 1 ].pack("VVQ<V")
    end
    count = entry_count || list.size
    body << [ 0x06054b50, 0, 0, count, count, directory_size, directory_offset, comment.bytesize ].pack("VvvvvVVv") << comment.b
    body << trailing_eocd if trailing_eocd
    body
  end
end
