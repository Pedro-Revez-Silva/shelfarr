# frozen_string_literal: true

require "test_helper"
require_relative "../../../../test_helpers/consumer_test_helper"
require_relative "../../../../test_helpers/fixed_layout_fixtures"

class API::Consumer::V1::FixedLayoutTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include FixedLayoutFixtures

  FORMATS = { "X-Shelfarr-Reader-Formats" => "epub,pdf,cbz" }.freeze

  setup do
    prepare_consumer_library
    @folder = File.join(@root, "Mixed Formats")
    FileUtils.mkdir_p(@folder)
    write_consumer_epub(File.join(@folder, "Mixed.epub"))
    File.binwrite(File.join(@folder, "Mixed.pdf"), fixed_layout_pdf(pages: 3))
    File.binwrite(File.join(@folder, "Mixed.cbz"), fixed_layout_zip(comic_pages(3, width: 8, height: 8)))
    @mixed = Book.create!(title: "Mixed Formats", author: "A. Reader", book_type: :ebook, file_path: @folder)
    @comic_path = File.join(@root, "A Comic.cbz")
    File.binwrite(@comic_path, fixed_layout_zip(comic_pages(12, width: 8, height: 8)))
    @comic = Book.create!(title: "A Comic", author: "An Artist", book_type: :comicbook, file_path: @comic_path)
  end
  teardown { FileUtils.remove_entry(@root) }

  def publication(book, headers = {})
    get "/api/consumer/v1/library/#{book.id}", headers: @headers.merge(headers)
    assert_response :success
    response.parsed_body
  end

  def asset_of(book, format)
    publication(book, FORMATS).fetch("assets").find { |asset| asset.fetch("format") == format }
  end

  test "installed readers keep the EPUB-only projection, scope and cursor identity" do
    legacy = publication(@mixed)
    assert_equal [ "epub" ], legacy.fetch("assets").map { |asset| asset.fetch("format") }
    assert_not legacy.key?("content_kind")
    assert_equal "ebook", legacy.fetch("book_type")
    get "/api/consumer/v1/library/#{@comic.id}", headers: @headers
    assert_response :not_found
    get "/api/consumer/v1/library", headers: @headers
    ids = response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    assert_not_includes ids, @comic.id.to_s
    response.parsed_body.fetch("items").each do |item|
      assert_not item.key?("content_kind")
      assert item.fetch("assets").all? { |asset| %w[epub mp3].include?(asset.fetch("format")) }
    end
    # The default cursor identity is unchanged: an explicit "epub" shares it,
    # while a fixed-layout selection is a different listing.
    get "/api/consumer/v1/library", params: { limit: 1 }, headers: @headers
    legacy_cursor = response.parsed_body.fetch("next_cursor")
    get "/api/consumer/v1/library", params: { limit: 1, cursor: legacy_cursor }, headers: @headers.merge("X-Shelfarr-Reader-Formats" => "epub")
    assert_response :success
    get "/api/consumer/v1/library", params: { limit: 1, cursor: legacy_cursor }, headers: @headers.merge(FORMATS)
    assert_response :bad_request
    get "/api/consumer/v1/library", params: { limit: 1 }, headers: @headers.merge("X-Shelfarr-Reader-Formats" => "cbz , pdf,epub,pdf")
    normalized = response.parsed_body.fetch("next_cursor")
    get "/api/consumer/v1/library", params: { limit: 1, cursor: normalized }, headers: @headers.merge(FORMATS)
    assert_response :success
    get "/api/consumer/v1/library", params: { limit: 1, cursor: normalized }, headers: @headers
    assert_response :bad_request
  end

  test "capable readers receive declared formats and comics as graphic ebooks" do
    assets = publication(@mixed, FORMATS).fetch("assets")
    assert_equal %w[cbz epub pdf], assets.map { |asset| asset.fetch("format") }.sort
    pdf = assets.find { |asset| asset.fetch("format") == "pdf" }
    assert_equal "application/pdf", pdf.fetch("media_type")
    assert_not pdf.key?("page_count")
    cbz = assets.find { |asset| asset.fetch("format") == "cbz" }
    assert_equal "application/vnd.comicbook+zip", cbz.fetch("media_type")
    assert_equal 3, cbz.fetch("page_count")
    assert_equal "/api/consumer/v1/library/#{@mixed.id}/assets/#{cbz.fetch("id")}/reading_order", cbz.fetch("reading_order_url")
    assert_equal [ "pdf" ], publication(@mixed, "X-Shelfarr-Reader-Formats" => "pdf").fetch("assets").map { |asset| asset.fetch("format") }
    assert_equal "book", publication(@mixed, FORMATS).fetch("content_kind")
    assert_equal "book", publication(@mixed, "X-Shelfarr-Reader-Formats" => "epub").fetch("content_kind")

    comic = publication(@comic, FORMATS)
    assert_equal "ebook", comic.fetch("book_type")
    assert_equal "graphic", comic.fetch("content_kind")
    assert_equal 12, comic.fetch("assets").sole.fetch("page_count")
    @mixed.update!(content_kind: :graphic)
    assert_equal "graphic", publication(@mixed, FORMATS).fetch("content_kind")
    get "/api/consumer/v1/library", params: { type: "ebook" }, headers: @headers.merge(FORMATS)
    assert_includes response.parsed_body.fetch("items").map { |item| item.fetch("id") }, @comic.id.to_s
    get "/api/consumer/v1/library", params: { type: "audiobook" }, headers: @headers.merge(FORMATS)
    assert_not_includes response.parsed_body.fetch("items").map { |item| item.fetch("id") }, @comic.id.to_s
    get "/api/consumer/v1/library", params: { type: "comicbook" }, headers: @headers.merge(FORMATS)
    assert_response :bad_request
    get "/api/consumer/v1/library/#{@comic.id}", headers: @headers.merge("X-Shelfarr-Reader-Formats" => "epub")
    assert_response :not_found
  end

  test "malformed reader format declarations are refused" do
    [ "", "EPUB", "epub,", ",pdf", "epub,,pdf", "epub,mobi", "cbr", "epub;pdf", "pdf," + ("x" * 64) ].each do |value|
      get "/api/consumer/v1/library", headers: @headers.merge("X-Shelfarr-Reader-Formats" => value)
      assert_response :bad_request, value.inspect
      assert_equal "invalid_request", response.parsed_body.fetch("error")
      get "/api/consumer/v1/library/#{@mixed.id}", headers: @headers.merge("X-Shelfarr-Reader-Formats" => value)
      assert_response :bad_request, value.inspect
      get "/api/consumer/v1/continue", headers: @headers.merge("X-Shelfarr-Reader-Formats" => value)
      assert_response :bad_request, value.inspect
    end
    get "/api/consumer/v1/library", headers: @headers.merge(FORMATS)
    assert_includes response.headers["Vary"], "X-Shelfarr-Reader-Formats"
  end

  test "unusable PDF and CBZ sidecars are never offered and never break the EPUB" do
    File.binwrite(File.join(@folder, "Mixed.pdf"), "not a pdf at all")
    File.binwrite(File.join(@folder, "Mixed.cbz"), fixed_layout_zip({ "../escape.png" => fixed_layout_png(width: 2, height: 2) }))
    File.binwrite(File.join(@folder, "Notes.cbr"), "Rar!")
    assert_equal [ "epub" ], publication(@mixed, FORMATS).fetch("assets").map { |asset| asset.fetch("format") }
    epub = publication(@mixed).fetch("assets").sole
    get epub.fetch("content_url"), headers: @headers
    assert_response :success
    put "/api/consumer/v1/library/#{@mixed.id}/progress", headers: @headers, as: :json,
      params: { asset_id: epub.fetch("id"), expected_version: 0, client_mutation_id: SecureRandom.uuid, locator: { href: "OEBPS/chapter.xhtml", locations: { progression: 0.5 } } }
    assert_response :success
    File.binwrite(@comic_path, "PK\x03\x04 truncated")
    assert_empty publication(@comic, FORMATS).fetch("assets")
  end

  test "the reading order is the exact generation's bounded ZIP metadata" do
    cbz = asset_of(@comic, "cbz")
    get cbz.fetch("reading_order_url"), headers: @headers
    assert_response :success
    body = response.parsed_body
    assert_equal({ "asset_id" => cbz.fetch("id"), "format" => "cbz" }, body.except("items"))
    items = body.fetch("items")
    assert_equal (1..12).to_a, items.map { |item| item.fetch("position") }
    assert_equal (1..12).map { |page| format("pages/%03d.png", page) }, items.map { |item| item.fetch("href") }
    assert_equal %w[compressed_size compression_method crc32 href local_header_offset media_type position size_bytes], items.first.keys.sort
    assert_not_includes response.body, @root
    assert_includes response.headers["Cache-Control"], "no-store"
    bytes = File.binread(@comic_path)
    first = items.first
    assert_equal "PK\x03\x04".b, bytes.byteslice(first.fetch("local_header_offset"), 4)
    epub = asset_of(@mixed, "epub")
    get "/api/consumer/v1/library/#{@mixed.id}/assets/#{epub.fetch("id")}/reading_order", headers: @headers
    assert_response :gone
    _, raw = APIToken.issue!(name: "Search only", user: users(:one), scopes: [ "search:read" ])
    get cbz.fetch("reading_order_url"), headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :forbidden
    File.rename(@comic_path, "#{@comic_path}.old")
    File.binwrite(@comic_path, fixed_layout_zip(comic_pages(2, width: 8, height: 8)))
    get cbz.fetch("reading_order_url"), headers: @headers
    assert_response :gone
    get "/api/consumer/v1/library/#{@comic.id}/assets/#{"0" * 64}/reading_order", headers: @headers
    assert_response :gone
  end

  test "PDF and CBZ bytes download as sandboxed attachments with ranges and transfer grants" do
    pdf = asset_of(@mixed, "pdf")
    get pdf.fetch("content_url"), headers: @headers.merge("Range" => "bytes=0-7")
    assert_response :partial_content
    assert_equal "%PDF-1.7", response.body
    assert_equal "application/pdf", response.media_type
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_includes response.headers["Content-Security-Policy"], "sandbox"
    assert_includes response.headers["Content-Security-Policy"], "default-src 'none'"
    epub = asset_of(@mixed, "epub")
    get epub.fetch("content_url"), headers: @headers
    assert_match(/\Ainline;/, response.headers["Content-Disposition"])
    assert_nil response.headers["Content-Security-Policy"]
    cbz = asset_of(@comic, "cbz")
    post "/api/consumer/v1/library/#{@comic.id}/assets/#{cbz.fetch("id")}/transfer_grant", headers: @headers
    assert_response :created
    get response.parsed_body.fetch("url")
    assert_response :success
    assert_equal File.binread(@comic_path), response.body.b
    assert_equal "application/vnd.comicbook+zip", response.media_type
  end

  test "PDF places name a bounded page of document.pdf and never a text position" do
    pdf = asset_of(@mixed, "pdf")
    url = "/api/consumer/v1/library/#{@mixed.id}/progress"
    base = { asset_id: pdf.fetch("id"), expected_version: 0 }
    place = { href: "document.pdf", type: "application/pdf", locations: { position: 2, totalProgression: 0.5, fragments: [ "page=2" ] } }
    [ place.merge(href: "OEBPS/chapter.xhtml"), place.merge(type: "application/xhtml+xml"), place.merge(type: nil),
      place.deep_merge(locations: { position: 0 }), place.deep_merge(locations: { position: 100_001 }),
      place.deep_merge(locations: { position: "2" }), place.deep_merge(locations: { fragments: [ "page=3" ] }),
      place.deep_merge(locations: { cfi: "epubcfi(/6/2!/4/2)" }), place.merge(extra: true),
      { href: "document.pdf", type: "application/pdf", locations: { totalProgression: 0.5 } } ].each do |locator|
      put url, params: base.merge(client_mutation_id: SecureRandom.uuid, locator: locator), headers: @headers, as: :json
      assert_response :unprocessable_entity, locator.inspect
    end
    assert_empty users(:one).consumer_progresses
    mutation = SecureRandom.uuid
    observed = 1.minute.ago.utc.iso8601(3)
    put url, params: base.merge(client_mutation_id: mutation, locator: place, observed_at: observed), headers: @headers, as: :json
    assert_response :success
    progress = response.parsed_body.fetch("progress")
    assert_equal 2, progress.fetch("locator").fetch("locations").fetch("position")
    assert_equal observed, progress.fetch("observed_at")
    put url, params: base.merge(client_mutation_id: mutation, locator: place, observed_at: observed), headers: @headers, as: :json
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("progress").fetch("version")
    put url, params: base.merge(client_mutation_id: SecureRandom.uuid, locator: place.deep_merge(locations: { position: 3, fragments: [ "page=3" ] }, title: "Page 3"),
      observed_at: 2.minutes.ago.utc.iso8601(3), expected_version: 1), headers: @headers, as: :json
    assert_response :conflict
    put url, params: base.merge(client_mutation_id: SecureRandom.uuid, locator: { href: "document.pdf", type: "application/pdf", locations: { position: 100_000 } },
      expected_version: 1), headers: @headers, as: :json
    assert_response :success
  end

  test "CBZ places must be the exact item of this generation's reading order" do
    cbz = asset_of(@comic, "cbz")
    get cbz.fetch("reading_order_url"), headers: @headers
    items = response.parsed_body.fetch("items")
    url = "/api/consumer/v1/library/#{@comic.id}/progress"
    base = { asset_id: cbz.fetch("id"), expected_version: 0 }
    page = ->(position, **overrides) { { href: items[position - 1]&.fetch("href"), type: "image/png", locations: { position: position, totalProgression: (position - 1) / 12.0 } }.deep_merge(overrides) }
    [ page.call(3, href: items[3].fetch("href")), page.call(3, type: "image/jpeg"), page.call(13, href: items.last.fetch("href")),
      page.call(3, locations: { position: 4 }), page.call(3, locations: { fragments: [ "page=3" ] }),
      page.call(3, locations: { cfi: "epubcfi(/6/2)" }), page.call(3, href: "pages/../pages/003.png"),
      page.call(3, locations: { totalProgression: 1.5 }) ].each do |locator|
      put url, params: base.merge(client_mutation_id: SecureRandom.uuid, locator: locator), headers: @headers, as: :json
      assert_response :unprocessable_entity, locator.inspect
    end
    put url, params: base.merge(client_mutation_id: SecureRandom.uuid, locator: page.call(3)), headers: @headers, as: :json
    assert_response :success
    assert_equal "pages/003.png", response.parsed_body.fetch("progress").fetch("locator").fetch("href")
    # A changed archive is a different edition: its old pages are not accepted.
    File.rename(@comic_path, "#{@comic_path}.old")
    File.binwrite(@comic_path, fixed_layout_zip(comic_pages(12, width: 8, height: 8)))
    put url, params: base.merge(client_mutation_id: SecureRandom.uuid, expected_version: 1, locator: page.call(4)), headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal 1, users(:one).consumer_progresses.find_by!(book: @comic).version
  end

  test "continue reading follows the declared formats" do
    pdf = asset_of(@mixed, "pdf")
    put "/api/consumer/v1/library/#{@mixed.id}/progress", headers: @headers, as: :json,
      params: { asset_id: pdf.fetch("id"), expected_version: 0, client_mutation_id: SecureRandom.uuid,
        locator: { href: "document.pdf", type: "application/pdf", locations: { position: 1 } } }
    assert_response :success
    get "/api/consumer/v1/continue", headers: @headers.merge(FORMATS)
    assert_includes response.parsed_body.fetch("items").map { |item| item.fetch("id") }, @mixed.id.to_s
    # An EPUB-only reader can't open the place, so it isn't offered there.
    get "/api/consumer/v1/continue", headers: @headers
    assert_not_includes response.parsed_body.fetch("items").map { |item| item.fetch("id") }, @mixed.id.to_s
    put "/api/consumer/v1/library/#{@comic.id}/reading_status", params: { status: "in_progress" }, headers: @headers.merge(FORMATS), as: :json
    assert_response :success
    assert_equal "graphic", response.parsed_body.fetch("content_kind")
    get "/api/consumer/v1/continue", params: { type: "ebook" }, headers: @headers.merge(FORMATS)
    assert_includes response.parsed_body.fetch("items").map { |item| item.fetch("id") }, @comic.id.to_s
  end

  test "Kobo's consumer asset check stays EPUB-only" do
    assert_equal [ "epub" ], Consumer::LibraryAssets.new(@mixed).list.map(&:format)
  end
end
