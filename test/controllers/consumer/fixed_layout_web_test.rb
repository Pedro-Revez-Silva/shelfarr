# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/fixed_layout_fixtures"

class Consumer::FixedLayoutWebTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include FixedLayoutFixtures

  setup do
    prepare_consumer_library
    @comic_path = File.join(@root, "A Comic.cbz")
    File.binwrite(@comic_path, fixed_layout_zip(comic_pages(3, width: 8, height: 8)))
    @comic = Book.create!(title: "A Comic", author: "An Artist", book_type: :comicbook, file_path: @comic_path)
    @pdf_path = File.join(@root, "A Manual.pdf")
    File.binwrite(@pdf_path, fixed_layout_pdf(pages: 2))
    @pdf = Book.create!(title: "A Manual", author: "A. Writer", book_type: :ebook, file_path: @pdf_path)
    sign_in_as(users(:one))
  end
  teardown { FileUtils.remove_entry(@root) }

  def publication_json
    JSON.parse(css_select("script[data-consumer-reader-target=publication]").sole.text)
  end

  test "the web library lists comics and PDFs and opens them in the page reader" do
    get consumer_library_path(type: "ebook")
    assert_select "a[href=?] .consumer-format", consumer_publication_path(@comic), text: "Comic"
    assert_select "a[href=?] .consumer-format", consumer_publication_path(@pdf), text: "PDF"
    get consumer_publication_path(@comic)
    assert_response :success
    assert_select ".consumer-pages[hidden]"
    assert_select "[data-consumer-reader-target=pageTools]"
    publication = publication_json
    assert_equal "ebook", publication.fetch("book_type")
    assert_equal "graphic", publication.fetch("content_kind")
    asset = publication.fetch("assets").sole
    assert_equal "/read/#{@comic.id}/assets/#{asset.fetch("id")}/reading_order", asset.fetch("reading_order_url")
    assert_equal({ "supported" => true }, publication.fetch("offline"))
    resources = JSON.parse(css_select("script[data-consumer-reader-target=pdfResources]").sole.text)
    assert_match(%r{\A/assets/pdfjs/pdf\.worker-\h+\.js\z}, resources.fetch("worker"))
    assert_match(%r{\A/assets/pdfjs/standard_fonts/LiberationSans-Regular-\h+\.ttf\z}, resources.dig("files", "standardFontDataUrl", "LiberationSans-Regular.ttf"))
    assert_operator resources.dig("files", "cMapUrl").size, :>, 100
    assert_not_includes response.body, @root

    get asset.fetch("reading_order_url")
    assert_response :success
    assert_equal asset.fetch("id"), response.parsed_body.fetch("asset_id")
    assert_equal 3, response.parsed_body.fetch("items").size
    get asset.fetch("content_url"), headers: { "Range" => "bytes=0-3" }
    assert_response :partial_content
    assert_equal "PK\x03\x04".b, response.body.b
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
  end

  test "an unusable comic is shown honestly, not opened" do
    File.binwrite(@comic_path, fixed_layout_zip({ "../escape.png" => fixed_layout_png(width: 2, height: 2) }))
    get consumer_publication_path(@comic)
    assert_response :success
    assert_select "h2", text: "No readable files are available"
    assert_select ".consumer-pages", count: 0
    assert_empty publication_json.fetch("assets")
  end

  test "web progress accepts page places and refuses text positions for pages" do
    get consumer_publication_path(@pdf)
    asset = publication_json.fetch("assets").sole
    headers = { "X-Shelfarr-Account" => users(:one).id.to_s }
    base = { asset_id: asset.fetch("id"), expected_version: 0, client_mutation_id: SecureRandom.uuid }
    put consumer_progress_path(@pdf), params: base.merge(locator: { href: "document.pdf", type: "application/pdf", locations: { position: 2, cfi: "epubcfi(/6/2)" } }), headers: headers, as: :json
    assert_response :unprocessable_entity
    put consumer_progress_path(@pdf), params: base.merge(locator: { href: "document.pdf", type: "application/pdf", locations: { position: 2, fragments: [ "page=2" ] } }), headers: headers, as: :json
    assert_response :success
    get consumer_library_path
    assert_select "a[href=?] .consumer-book-state", consumer_publication_path(@pdf), text: "Page 2"
  end

  test "offline publication refresh includes comic records" do
    get consumer_offline_publications_path(ids: [ @comic.id, @ebook.id ].join(","))
    assert_response :success
    ids = response.parsed_body.fetch("publications").map { |publication| publication.fetch("id") }
    assert_equal [ @comic.id.to_s, @ebook.id.to_s ].sort, ids.sort
    comic = response.parsed_body.fetch("publications").find { |publication| publication.fetch("id") == @comic.id.to_s }
    assert comic.dig("offline", "supported")
    assert comic.fetch("assets").sole.fetch("reading_order_url").start_with?("/read/")
  end
end
