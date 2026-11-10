# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_test_helper"

# A plain library EPUB delivered to a stock Kobo as a Kobo edition (KEPUB)
# prepared from it, with reading places shared both ways for that edition.
class Kobo::KepubEditionTest < ActiveSupport::TestCase
  include KoboTestHelper

  setup do
    prepare_kobo_book
    prepare_plain_epub
    @user = users(:one)
    @device.update!(share_progress: true, receive_progress: true)
    @original = File.binread(@path)
    @original_stat = File.stat(@path)
  end

  teardown { FileUtils.remove_entry(@root) }

  def sync(cursor, device = @device, token = @token)
    KoboSync.new(device.reload, endpoint: device.endpoint(token)).call(cursor)
  end

  def asset_id
    Consumer::LibraryAssets.new(@book).list.sole.id
  end

  def read_in_shelfarr(href: "OEBPS/Text/ch2.xhtml", progression: 0.5, total: 0.5, at: 2.hours.ago, **extra)
    current = @user.consumer_progresses.find_by(book: @book)
    locator = { "href" => href, "type" => "application/xhtml+xml", "locations" => { "progression" => progression, "totalProgression" => total }.merge(extra) }
    Consumer::ProgressWriter.new(user: @user, book: @book).call("asset_id" => asset_id, "expected_version" => current&.version || 0,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => at&.utc&.iso8601(3), "locator" => locator)
  end

  def kobo_bookmark(span:, source:, at:, chapter_percent: 40, percent: 75)
    { "LastModified" => at.utc.strftime("%Y-%m-%dT%H:%M:%S.%7NZ"), "ProgressPercent" => percent, "ContentSourceProgressPercent" => chapter_percent,
      "Location" => { "Type" => "KoboSpan", "Source" => source, "Value" => span } }
  end

  def kobo_uploads(delivery, bookmark)
    delivery.reload
    delivery.update_columns(reading_state: (delivery.reading_state || {}).merge("CurrentBookmark" => bookmark))
    Kobo::ProgressBridge.new(delivery).call(bookmark)
  end

  def delivered_bytes(delivery)
    file = delivery.open_file
    file.read
  ensure
    file&.close
  end

  def progress
    @user.consumer_progresses.find_by(book: @book)
  end

  def state_items(result)
    result.items.filter_map { |item| item.dig("ChangedReadingState", "ReadingState") }
  end

  def span_text(entries, path, id)
    Nokogiri::XML(entries.fetch(path)).at_xpath("//*[@id=$id]", nil, id: id).text
  end

  def assert_library_file_untouched
    assert_equal @original, File.binread(@path), "the library EPUB is never rewritten"
    stat = File.stat(@path)
    assert_equal [ @original_stat.ino, @original_stat.mtime, @original_stat.ctime ], [ stat.ino, stat.mtime, stat.ctime ]
  end

  test "a plain EPUB 3 is delivered as a Kobo edition with real sentence markers while the library file stays original" do
    delivery = @device.send_book!(@book)
    publication = delivery.publication
    assert_equal [ "KEPUB", "Book.kepub.epub", "EPUB" ], publication.values_at("format", "filename", "source_format")
    copy = delivery.kobo_kepub_copy
    assert_equal [ copy.id, copy.sha256, Digest::SHA256.hexdigest(@original), Kobo::KepubConverter::VERSION ],
      publication.fetch("kepub").values_at("copy_id", "sha256", "source_sha256", "converter")

    bytes = delivered_bytes(delivery)
    assert_equal [ copy.size_bytes, publication.fetch("size") ], [ bytes.bytesize, bytes.bytesize ]
    assert_equal copy.sha256, Digest::SHA256.hexdigest(bytes)
    assert_equal "mimetypeapplication/epub+zip", bytes[30, 28], "the mimetype entry is first, stored and without extra fields"
    metadata = sync(nil).items.sole.dig("NewEntitlement", "BookMetadata")
    assert_equal [ [ "KEPUB", bytes.bytesize ] ], metadata.fetch("DownloadUrls").map { |url| url.values_at("Format", "Size") }

    source = zip_entries(@path)
    delivered = zip_entries(StringIO.new(bytes))
    chapters = [ "OEBPS/Text/chapter 1.xhtml", "OEBPS/Text/ch2.xhtml", "OEBPS/Text/ch3.xhtml" ]
    assert_equal source.keys, delivered.keys, "every path is kept, including the encoded chapter name"
    (source.keys - chapters).each { |name| assert_equal source[name], delivered[name], "#{name} is copied unchanged" }
    chapters.each do |path|
      original = Kobo::SpanIndex.new(source[path], require_spans: false)
      converted = Kobo::SpanIndex.new(delivered[path])
      assert_equal original.text, converted.text, "#{path} keeps every character of its text"
      assert_operator converted.span_ids.size, :>=, 30
    end
    chapter = delivered.fetch("OEBPS/Text/ch2.xhtml")
    assert_includes chapter, %(<div id="book-columns"><div id="book-inner">)
    assert_includes chapter, %(class="kobostylehacks")
    assert_includes chapter, %(<em><span class="koboSpan" id="kobo.4.3">second</span></em>), "inline markup is kept around its own span"
    assert_equal "Chapter 2 paragraph 3 begins here. ", span_text(delivered, "OEBPS/Text/ch2.xhtml", "kobo.4.1")
    assert_equal "“And a third?” ", span_text(delivered, "OEBPS/Text/ch2.xhtml", "kobo.4.5")
    assert_includes chapter, %(<span class="koboSpan" id="kobo.7.1"><img src="../Images/pic.png" alt="A picture"/></span>)
    assert_includes chapter, %(<a id="c2end"></a>), "an empty anchor is written with an end tag"
    assert_includes chapter, "Ünïcödé &amp; more"
    assert_library_file_untouched
  end

  test "a Shelfarr place in the original reaches the copy's matching sentence by an incremental state-only sync" do
    delivery = @device.send_book!(@book)
    first = sync(nil)
    delivery.update!(last_download_at: 1.day.ago)
    revision, file_revision = delivery.reload.values_at(:revision_id, :file_sync_revision)
    read_at = 2.hours.ago.utc.floor(3)
    # The web reader's CFI for paragraph 3's text after <em> ("se|ntence!"),
    # in the original tree: /4 is <body>, /8 its fourth element child.
    cfi = "epubcfi(/6/4!/4/8[c2p3]/3:4)"
    saved = read_in_shelfarr(at: read_at, progression: 0.9, cfi: cfi)

    second = sync(first.token)
    assert_equal [ "ChangedReadingState" ], second.items.map { |item| item.keys.sole }
    state = state_items(second).sole
    location = state.dig("CurrentBookmark", "Location")
    assert_equal({ "Type" => "KoboSpan", "Source" => "OEBPS/Text/ch2.xhtml", "Value" => "kobo.4.4" }, location)
    assert_equal " sentence! ", span_text(zip_entries(StringIO.new(delivered_bytes(delivery))), "OEBPS/Text/ch2.xhtml", "kobo.4.4"),
      "the span holds the very text the CFI names in the original"
    assert_equal "cfi", delivery.reload.progress_outbound["method"]
    assert_equal [ read_at.iso8601(3) ] * 2, [ state.dig("CurrentBookmark", "LastModified"), state["PriorityTimestamp"] ]
    assert_equal [ revision, file_revision ], delivery.values_at(:revision_id, :file_sync_revision), "nothing is downloaded again"
    assert_equal saved.attributes, progress.attributes

    # Negative control: the same CFI resolved against the copy's own tree
    # (whose body is now wrapped) names a different place.
    copy_chapter = Kobo::SpanIndex.new(zip_entries(StringIO.new(delivered_bytes(delivery))).fetch("OEBPS/Text/ch2.xhtml"))
    assert_not_equal "kobo.4.4", copy_chapter.locate(saved.locator, spine_index: 1).span
    assert_library_file_untouched
  end

  test "an encoded chapter path and a fragment place map into the copy" do
    delivery = @device.send_book!(@book)
    first = sync(nil)
    delivery.update!(last_download_at: 1.day.ago)
    read_in_shelfarr(href: "OEBPS/Text/chapter%201.xhtml", progression: 0.1, total: 0.1, fragments: [ "c1p5" ])
    location = state_items(sync(first.token)).sole.dig("CurrentBookmark", "Location")
    assert_equal [ "OEBPS/Text/chapter 1.xhtml", "kobo.6.1" ], location.values_at("Source", "Value")
    assert_equal "fragment", delivery.reload.progress_outbound["method"]
  end

  test "Kobo reading in the copy updates the original asset at the Kobo's own reading time, and echoes are not reading" do
    delivery = @device.send_book!(@book)
    first = sync(nil)
    delivery.update!(last_download_at: 1.day.ago)
    read_in_shelfarr(at: 3.hours.ago, cfi: "epubcfi(/6/4!/4/8/3:4)")
    sent = state_items(sync(first.token)).sole.dig("CurrentBookmark", "Location")
    before = progress.attributes

    assert_equal "echo", kobo_uploads(delivery, kobo_bookmark(span: sent["Value"], source: "#{delivery.entitlement_id}!!#{sent['Source']}", at: 1.minute.ago))["status"]
    assert_equal before, progress.attributes, "an adoption echo is neither a version nor a time"

    read_at = 20.minutes.ago.utc.floor(3)
    shared = kobo_uploads(delivery, kobo_bookmark(span: "kobo.3.2", source: "OEBPS/Text/chapter 1.xhtml", at: read_at, chapter_percent: 40, percent: 12))
    assert_equal "shared", shared["status"]
    saved = progress
    assert_equal asset_id, saved.asset_id, "the place belongs to the original library asset, not the copy"
    assert_equal "OEBPS/Text/chapter%201.xhtml", saved.locator["href"], "the manifest's own spelling of the original chapter"
    assert_equal({ "progression" => 0.4, "totalProgression" => 0.12 }, saved.locator["locations"])
    assert_equal read_at, saved.observed_at, "the Kobo's own reading time, not the upload time"
    assert_empty sync(first.token).items, "this reader's own place is not sent back"
    assert_library_file_untouched
  end

  test "a plain EPUB 2 with an NCX, an XHTML 1.1 document type and an entity keeps its navigation and maps places" do
    prepare_plain_epub(version: 2, chapters: { "OEBPS/Text/ch2.xhtml" => plain_chapter(2, doctype: :xhtml11).sub("begins here.", "begins&nbsp;here.") })
    @original = File.binread(@path)
    @original_stat = File.stat(@path)
    delivery = @device.send_book!(@book)
    assert_equal [ "KEPUB", "2.0" ], delivery.publication.values_at("format", "epub_version")
    delivered = zip_entries(StringIO.new(delivered_bytes(delivery)))
    source = zip_entries(@path)
    assert_equal source["OEBPS/toc.ncx"], delivered["OEBPS/toc.ncx"]
    assert_equal source["OEBPS/content.opf"], delivered["OEBPS/content.opf"]
    assert_includes delivered["OEBPS/Text/ch2.xhtml"], "-//W3C//DTD XHTML 1.1//EN"
    assert_includes delivered["OEBPS/Text/ch2.xhtml"], "&nbsp;", "an entity stays a reference rather than being expanded"

    first = sync(nil)
    delivery.update!(last_download_at: 1.day.ago)
    read_in_shelfarr(cfi: "epubcfi(/6/4!/4/8/3:4)")
    location = state_items(sync(first.token)).sole.dig("CurrentBookmark", "Location")
    assert_equal " sentence! ", span_text(delivered, "OEBPS/Text/ch2.xhtml", location.fetch("Value"))
    assert_equal KoboPublication.new(@book).cover(File.open(@path, "rb")), delivery.cover
    assert_library_file_untouched
  end

  test "sending again reuses the verified copy, and a lost or corrupted copy is rebuilt byte for byte" do
    delivery = @device.send_book!(@book)
    copy = delivery.kobo_kepub_copy
    expected = delivered_bytes(delivery)

    Kobo::KepubConverter.stub(:new, ->(*) { flunk "a ready copy is not converted again" }) do
      again = @device.send_book!(@book)
      assert_equal [ copy.id, delivery.revision_id != again.revision_id ], [ again.kobo_kepub_copy_id, true ]
      assert_equal 1, KoboKepubCopy.count
    end

    path = Kobo::KepubCache.root.join(copy.storage_key)
    File.unlink(path)
    assert_equal expected, delivered_bytes(delivery.reload), "a restart without the cache file rebuilds the same bytes"

    File.open(path, "r+b") do |file|
      file.seek(40)
      file.write("X")
    end
    assert_equal expected, delivered_bytes(delivery.reload), "a copy changed on disk is never served"
    assert_equal 1, KoboKepubCopy.count
    assert_library_file_untouched
  end

  test "a copy that cannot be rebuilt identically is refused instead of serving different bytes" do
    delivery = @device.send_book!(@book)
    File.unlink(Kobo::KepubCache.root.join(delivery.kobo_kepub_copy.storage_key))
    delivery.kobo_kepub_copy.update_columns(sha256: "f" * 64)
    delivery.update_columns(publication: delivery.publication.deep_merge("kepub" => { "sha256" => "f" * 64 }))
    error = assert_raises(KoboPublication::Unavailable) { delivery.reload.open_file }
    assert_match(/send the book again/, error.message)
  end

  test "a replaced library file never serves its earlier copy, and sending again prepares a new edition" do
    delivery = @device.send_book!(@book)
    old_copy = delivery.kobo_kepub_copy
    delivery.update!(last_download_at: 1.hour.ago)
    prepare_plain_epub(chapters: { "OEBPS/Text/ch2.xhtml" => plain_chapter(2, paragraphs: 6) })

    assert_raises(KoboPublication::Unavailable) { delivery.reload.open_file }
    resent = @device.send_book!(@book)
    assert_not_equal old_copy.id, resent.kobo_kepub_copy_id
    assert resent.progress_generation_ambiguous?, "a reader that downloaded the earlier copy may still have it"
    assert_nil resent.last_download_at
    assert_equal Digest::SHA256.hexdigest(File.binread(@path)), resent.publication.dig("kepub", "source_sha256")
  end

  test "an EPUB first delivered before Kobo editions keeps its bytes until it is sent again explicitly" do
    legacy = KoboPublication.new(@book).snapshot.except("kepub", "source_format", "source_size")
      .merge("format" => "EPUB", "filename" => "Book.epub", "size" => @original.bytesize)
    delivery = @device.send(:publish!, { book: @book }, legacy)
    delivery.update!(last_download_at: 1.hour.ago, reading_state: { "CurrentBookmark" => { "ProgressPercent" => 10 } })
    assert_equal @original, delivered_bytes(delivery)
    assert_equal [ [ "EPUB3", @original.bytesize ], [ "EPUB", @original.bytesize ] ],
      sync(nil).items.sole.dig("NewEntitlement", "BookMetadata", "DownloadUrls").map { |url| url.values_at("Format", "Size") }
    read_in_shelfarr
    sync(nil)
    assert_equal %w[unsupported plain_epub], delivery.reload.progress_outbound.values_at("status", "reason")

    resent = @device.send_book!(@book)
    assert_equal [ delivery.id, "KEPUB" ], [ resent.id, resent.publication["format"] ]
    assert resent.progress_generation_ambiguous?, "the plain copy on the reader is a different file"
    assert_nil resent.reading_state
  end

  test "a full Kobo edition cache refuses to send and keeps every referenced copy, evicting only unused ones" do
    delivery = @device.send_book!(@book)
    kept = delivery.kobo_kepub_copy
    books = %w[Unused Other].map do |title|
      path = File.join(@root, "#{title}.epub")
      write_plain_epub(path, chapters: { "OEBPS/Text/ch3.xhtml" => plain_chapter(3, paragraphs: title.size + 3) })
      Book.create!(title: title, author: "Author", book_type: :ebook, file_path: path)
    end
    unused = @device.send_book!(books.first).tap(&:destroy!).kobo_kepub_copy
    unused.update_columns(last_used_at: 2.hours.ago)
    kept.update_columns(last_used_at: 2.hours.ago)
    other = books.last

    with_env("KOBO_KEPUB_CACHE_MAX_BYTES" => (kept.size_bytes + 1000).to_s) do
      error = assert_raises(KoboPublication::Unavailable) { @device.send_book!(other) }
      assert_match(/space is full.*nothing was changed/, error.message)
    end
    assert_not KoboKepubCopy.exists?(unused.id), "an unreferenced, unused copy is evicted first"
    assert KoboKepubCopy.exists?(kept.id)
    assert_nil @device.kobo_deliveries.find_by(book: other)
    assert_equal kept.sha256, Digest::SHA256.hexdigest(delivered_bytes(delivery.reload)), "the delivered copy keeps working"
  end

  test "a busy cache and a crashed worker never leave a partial or orphan copy" do
    root = Kobo::KepubCache.root
    FileUtils.mkdir_p(root.join(".incoming"), mode: 0o700)
    File.write(root.join(".incoming", "#{'1' * 32}.part"), "partial")
    FileUtils.mkdir_p(root.join("ab"), mode: 0o700)
    File.write(root.join("ab", "#{'ab' * 32}.kepub.epub"), "renamed before its row committed")

    File.open(root.join(".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      Kobo::KepubCache.lock_wait = 0.2
      error = assert_raises(KoboPublication::Unavailable) { @device.send_book!(@book) }
      assert_match(/being prepared/, error.message)
    ensure
      Kobo::KepubCache.lock_wait = nil
    end
    assert_empty @device.kobo_deliveries

    delivery = @device.send_book!(@book)
    assert_equal "KEPUB", delivery.publication["format"]
    assert_empty Dir.children(root.join(".incoming"))
    assert_not File.exist?(root.join("ab", "#{'ab' * 32}.kepub.epub"))
    assert_equal [ delivery.kobo_kepub_copy.storage_key ], Dir.glob("*/*.kepub.epub", base: root)
    assert_equal "700", format("%o", File.stat(root).mode & 0o777)
    assert_equal "600", format("%o", File.stat(root.join(delivery.kobo_kepub_copy.storage_key)).mode & 0o777)
  end

  test "an EPUB whose copy cannot be made safely is delivered as itself with the reason" do
    prepare_plain_epub(chapters: { "OEBPS/Text/ch2.xhtml" => "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>Unclosed</body></html>" })
    delivery = @device.send_book!(@book)
    assert_equal [ "EPUB", "Book.epub", "not_well_formed", nil ], delivery.publication.values_at("format", "filename", "kepub_unavailable", "kepub")
    assert_nil delivery.kobo_kepub_copy_id
    assert_equal File.binread(@path), delivered_bytes(delivery)
    first = sync(nil)
    delivery.update!(last_download_at: 1.hour.ago)
    read_in_shelfarr
    sync(first.token)
    assert_equal [ "unsupported", "kepub_unavailable", "not_well_formed" ], delivery.reload.progress_outbound.values_at("status", "reason", "kepub_reason")
  end

  # A converter that drops a character of text, to prove a copy is checked
  # against its source before anything can use it.
  class LossyConverter < Kobo::KepubConverter
    private

    def convert(data)
      output, count = super
      [ output.sub("begins here", "begins her"), count ]
    end
  end

  test "a copy whose text differs from the original is never stored or delivered" do
    Kobo::KepubConverter.stub(:new, ->(source) { LossyConverter.allocate.tap { |converter| converter.send(:initialize, source) } }) do
      delivery = @device.send_book!(@book)
      assert_equal [ "EPUB", "verification_failed" ], delivery.publication.values_at("format", "kepub_unavailable")
    end
    assert_equal 0, KoboKepubCopy.count
    assert_empty Dir.glob("**/*.{part,epub}", base: Kobo::KepubCache.root)
  end

  test "existing KEPUB library files keep passing through unchanged" do
    prepare_kobo_kepub
    delivery = @device.send_book!(@book)
    assert_equal [ "KEPUB", "Book.kepub.epub", nil ], delivery.publication.values_at("format", "filename", "kepub")
    assert_nil delivery.kobo_kepub_copy_id
    assert_equal File.binread(@path), delivered_bytes(delivery)
    assert_not Kobo::KepubCache.root.exist?, "no Kobo edition is prepared"
  end
end
