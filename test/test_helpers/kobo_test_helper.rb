# frozen_string_literal: true

require "zip"

module KoboTestHelper
  def prepare_kobo_book
    @root = Dir.mktmpdir("kobo")
    SettingsService.set(:ebook_output_path, @root)
    @path = File.join(@root, "Book.epub")
    write_epub(@path)
    @book = Book.create!(title: "A Library Book", author: "An Author", book_type: :ebook, file_path: @path)
    @device, @token = KoboDevice.issue(user: users(:one), name: "My Kobo", base_url: "https://shelfarr.example")
    @device.save!
  end

  KEPUB_PACKAGE = <<~XML
    <package version="3.0"><manifest>
      <item id="c1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
      <item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
      <item id="c3" href="Text/ch3.xhtml" media-type="application/xhtml+xml"/>
      <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
    </manifest><spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine></package>
  XML

  # A chapter as kepubify writes it: an XHTML document type, Kobo's wrapper
  # divs and a koboSpan per sentence ("kobo.<paragraph>.<sentence>").
  # Every sentence has exactly 40 characters of text, so offsets are known.
  def kepub_chapter(number, paragraphs: 5, first: 1)
    body = paragraphs.times.map do |index|
      paragraph = first + index
      sentences = 2.times.map { |sentence| %(<span class="koboSpan" id="kobo.#{paragraph}.#{sentence + 1}">#{format('C%02d P%03d S%d ', number, paragraph, sentence + 1).ljust(40, '.')}</span>) }
      %(<p id="p#{paragraph}">#{sentences.join}</p>)
    end
    <<~XHTML
      <?xml version="1.0" encoding="utf-8"?>
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter #{number}</title></head>
      <body><div class="book-inner"><div class="book-columns">#{body.join}</div></div></body></html>
    XHTML
  end

  # A three-chapter KEPUB library file, delivered to Kobo as KEPUB.
  def prepare_kobo_kepub(chapters: {})
    File.unlink(@path) if @path && File.exist?(@path)
    @path = File.join(@root, "Book.kepub.epub")
    write_epub(@path, package: KEPUB_PACKAGE, extra: {
      "OEBPS/Text/chapter 1.xhtml" => kepub_chapter(1), "OEBPS/Text/ch2.xhtml" => kepub_chapter(2, first: 3),
      "OEBPS/Text/ch3.xhtml" => kepub_chapter(3)
    }.merge(chapters))
    @book.update!(file_path: @path)
  end

  PLAIN_EPUB3_PACKAGE = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:plain-epub-3</dc:identifier><dc:title>Plain</dc:title><dc:language>en</dc:language></metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="c1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
        <item id="c3" href="Text/ch3.xhtml" media-type="application/xhtml+xml"/>
        <item id="css" href="Styles/book.css" media-type="text/css"/>
        <item id="pic" href="Images/pic.png" media-type="image/png"/>
        <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
      </manifest>
      <spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine>
    </package>
  XML

  PLAIN_EPUB2_PACKAGE = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">plain-epub-2</dc:identifier><dc:title>Plain</dc:title><meta name="cover" content="cover"/></metadata>
      <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="c1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
        <item id="c3" href="Text/ch3.xhtml" media-type="application/xhtml+xml"/>
        <item id="css" href="Styles/book.css" media-type="text/css"/>
        <item id="pic" href="Images/pic.png" media-type="image/png"/>
        <item id="cover" href="cover.png" media-type="image/png"/>
      </manifest>
      <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine>
    </package>
  XML

  # An ordinary chapter as publishers and Calibre write it: no Kobo markup,
  # inline elements, Unicode, an anchor, an image and an entity. Paragraph N
  # holds "Chapter C paragraph N begins here. It has a <em>second</em> sentence!
  # “And a third?” Finally ends." so each sentence is easy to find in a copy.
  def plain_chapter(number, doctype: :html5, paragraphs: 5)
    body = paragraphs.times.map do |index|
      n = index + 1
      %(<p id="c#{number}p#{n}">Chapter #{number} paragraph #{n} begins here. It has a <em>second</em> sentence! “And a third?” Finally ends.</p>)
    end
    declaration = doctype == :xhtml11 ? %(<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">) : "<!DOCTYPE html>"
    <<~XHTML
      <?xml version="1.0" encoding="utf-8"?>
      #{declaration}
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Chapter #{number}</title><link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
      <body><h2 id="c#{number}h" epub:type="title">Chapter #{number} — Ünïcödé &amp; more</h2>
      #{body.join("\n")}
      <div class="figure"><img src="../Images/pic.png" alt="A picture"/></div><p>Last words<a id="c#{number}end"/></p>
      </body></html>
    XHTML
  end

  PLAIN_NAV = <<~XHTML
    <?xml version="1.0" encoding="utf-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
    <body><nav epub:type="toc"><ol><li><a href="Text/chapter%201.xhtml">One</a></li><li><a href="Text/ch2.xhtml#c2p3">Two</a></li><li><a href="Text/ch3.xhtml">Three</a></li></ol></nav></body></html>
  XHTML

  PLAIN_NCX = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="plain-epub-2"/></head><docTitle><text>Plain</text></docTitle>
    <navMap><navPoint id="n1" playOrder="1"><navLabel><text>One</text></navLabel><content src="Text/chapter%201.xhtml"/></navPoint><navPoint id="n2" playOrder="2"><navLabel><text>Two</text></navLabel><content src="Text/ch2.xhtml#c2p3"/></navPoint></navMap></ncx>
  XML

  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")

  # A three-chapter DRM-free plain EPUB 2 or 3 library file (no Kobo markup).
  def prepare_plain_epub(version: 3, chapters: {})
    File.unlink(@path) if @path && File.exist?(@path)
    @path = File.join(@root, "Book.epub")
    write_plain_epub(@path, version: version, chapters: chapters)
    @book.update!(file_path: @path)
  end

  def write_plain_epub(path, version: 3, chapters: {})
    doctype = version == 2 ? :xhtml11 : :html5
    navigation = version == 2 ? { "OEBPS/toc.ncx" => PLAIN_NCX } : { "OEBPS/nav.xhtml" => PLAIN_NAV }
    write_epub(path, package: version == 2 ? PLAIN_EPUB2_PACKAGE : PLAIN_EPUB3_PACKAGE, extra: {
      "OEBPS/Text/chapter 1.xhtml" => plain_chapter(1, doctype: doctype), "OEBPS/Text/ch2.xhtml" => plain_chapter(2, doctype: doctype),
      "OEBPS/Text/ch3.xhtml" => plain_chapter(3, doctype: doctype), "OEBPS/Styles/book.css" => "p { text-indent: 1em; }\nbody > p { margin: 0; }\n",
      "OEBPS/Images/pic.png" => PNG
    }.merge(navigation).merge(chapters))
  end

  def zip_entries(path_or_io)
    io = path_or_io.is_a?(String) ? File.open(path_or_io, "rb") : path_or_io
    Zip::File.open_buffer(io.read).then { |zip| zip.entries.to_h { |entry| [ entry.name, entry.get_input_stream.read.force_encoding(Encoding::UTF_8) ] } }
  ensure
    io.close if path_or_io.is_a?(String)
  end

  def write_epub(path, version: "3.0", extra: {}, package: nil)
    File.unlink(path) if File.exist?(path)
    entries = {
      "mimetype" => "application/epub+zip",
      "META-INF/container.xml" => '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
      "OEBPS/content.opf" => package || %(<package version="#{version}"><manifest><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/></manifest></package>),
      "OEBPS/cover.png" => Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")
    }.merge(extra)
    Zip::File.open(path, create: true) do |zip|
      entries.each { |name, contents| zip.get_output_stream(name) { |out| out.write(contents) } }
    end
  end
end
