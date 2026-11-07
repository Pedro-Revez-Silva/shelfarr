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
