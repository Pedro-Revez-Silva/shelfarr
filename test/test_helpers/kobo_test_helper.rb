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
