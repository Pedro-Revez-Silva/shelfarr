# frozen_string_literal: true

require "zip"

module ConsumerTestHelper
  OFFLINE_STORAGE = "service_workers,cache_storage,indexeddb,local_storage"

  # Removes everything offline reading keeps for the test server's origin:
  # worker registrations, Cache Storage, IndexedDB (accounts and downloads)
  # and localStorage. Cookies stay; sign-in sets the session separately.
  #
  # This goes through the browser, not page script. A page's unregister() is
  # queued behind the worker's update check, which Chrome starts after each
  # navigation the worker controls, so it lasts as long as that request does;
  # and deleteDatabase() only reports "blocked" while a connection stays open.
  # Chrome's own clear cancels both and returns once the data is gone.
  def clear_browser_offline_state
    page.driver.browser.execute_cdp("Storage.clearDataForOrigin", origin: page.server.base_url, storageTypes: OFFLINE_STORAGE)
  end

  def prepare_consumer_library
    @root = Dir.mktmpdir("consumer-library")
    SettingsService.set(:ebook_output_path, @root)
    SettingsService.set(:audiobook_output_path, @root)
    @epub_path = File.join(@root, "A Book.epub")
    write_consumer_epub(@epub_path)
    @ebook = Book.create!(title: "The Quiet Library", author: "A. Reader", book_type: :ebook, file_path: @epub_path)
    @audio_path = File.join(@root, "An Audio Book.mp3")
    File.binwrite(@audio_path, "an audio stream of known bytes")
    @audiobook = Book.create!(title: "A Listening Life", author: "A. Listener", book_type: :audiobook, file_path: @audio_path)
    @token, raw = APIToken.issue!(name: "Test consumer", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES)
    @headers = { "Authorization" => "Bearer #{raw}" }
  end

  def write_consumer_epub(path, chapter: "A quiet place to begin reading.", second_chapter: nil)
    entries = {
      "mimetype" => "application/epub+zip",
      "META-INF/container.xml" => '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      "OEBPS/content.opf" => '<package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier><dc:title>The Quiet Library</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-07T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>',
      "OEBPS/nav.xhtml" => '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">A beginning</a></li></ol></nav></body></html>',
      "OEBPS/chapter.xhtml" => %(<html xmlns="http://www.w3.org/1999/xhtml"><head><title>A beginning</title></head><body><h1>A beginning</h1><p>#{chapter}</p></body></html>)
    }
    if second_chapter
      entries["OEBPS/content.opf"] = entries["OEBPS/content.opf"].sub("</manifest>", '<item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest>')
      entries["OEBPS/content.opf"] = entries["OEBPS/content.opf"].sub("</spine>", '<itemref idref="two"/></spine>')
      entries["OEBPS/two.xhtml"] = %(<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Another chapter</title></head><body><h1>Another chapter</h1><p>#{second_chapter}</p></body></html>)
    end
    Zip::File.open(path, create: true) { |zip| entries.each { |name, content| zip.get_output_stream(name) { |out| out.write(content) } } }
  end

  def consumer_asset(book)
    Consumer::LibraryAssets.new(book).list.first
  end

  def audio_progress(asset_id: consumer_asset(@audiobook).id, version: 0, mutation: SecureRandom.uuid, seconds: 17.5)
    { asset_id: asset_id, expected_version: version, client_mutation_id: mutation, position_seconds: seconds }
  end
end
