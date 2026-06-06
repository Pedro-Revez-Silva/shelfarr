# frozen_string_literal: true

require "test_helper"

class GutenbergClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:gutenberg_enabled, true)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")
    SettingsService.set(:gutenberg_search_limit, 10)
    GutenbergClient.reset_connection!
  end

  teardown do
    SettingsService.set(:gutenberg_enabled, false)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")
    SettingsService.set(:gutenberg_search_limit, 10)
    GutenbergClient.reset_connection!
  end

  test "search raises when disabled" do
    SettingsService.set(:gutenberg_enabled, false)

    assert_raises GutenbergClient::NotConfiguredError do
      GutenbergClient.search(title: "Pride and Prejudice")
    end
  end

  test "search returns ebook results from Project Gutenberg OPDS" do
    stub_search_feed(query: "Pride and Prejudice Jane Austen", ids: [ 1342 ])
    stub_detail_feed(
      1342,
      title: "Pride and Prejudice",
      author: "Austen, Jane",
      language: "en",
      links: [
        { type: "application/epub+zip", title: "EPUB (no images, older E-readers)", href: "https://www.gutenberg.org/ebooks/1342.epub.noimages" },
        { type: "application/epub+zip", title: "EPUB3 (E-readers incl. Send-to-Kindle)", href: "https://www.gutenberg.org/ebooks/1342.epub3.images" }
      ]
    )

    results = GutenbergClient.search(title: "Pride and Prejudice", author: "Jane Austen", language: "en")

    assert_equal 1, results.size
    result = results.first
    assert_equal "1342", result.id
    assert_equal "Pride and Prejudice", result.title
    assert_equal "Austen, Jane", result.author
    assert_equal "en", result.language
    assert_equal "epub", result.file_type
    assert_equal "https://www.gutenberg.org/ebooks/1342.epub3.images", result.download_url
    assert_equal "https://www.gutenberg.org/ebooks/1342", result.info_url
    assert result.downloadable?
  end

  test "search filters mismatched languages from detail feed" do
    stub_search_feed(query: "Le Livre", ids: [ 123 ])
    stub_detail_feed(
      123,
      title: "Le Livre",
      author: "Auteur, Exemple",
      language: "fr",
      links: [
        { type: "application/epub+zip", title: "EPUB3", href: "https://www.gutenberg.org/ebooks/123.epub3.images" }
      ]
    )

    assert_empty GutenbergClient.search(title: "Le Livre", language: "en")
  end

  test "search filters results without supported ebook acquisition links" do
    stub_search_feed(query: "Plain Text Only", ids: [ 1 ])
    stub_detail_feed(
      1,
      title: "Plain Text Only",
      author: "Writer, Test",
      language: "en",
      links: [
        { type: "text/plain", title: "Plain Text UTF-8", href: "https://www.gutenberg.org/files/1/1-0.txt" }
      ]
    )

    assert_empty GutenbergClient.search(title: "Plain Text Only")
  end

  test "search falls back to mobi when epub is unavailable" do
    stub_search_feed(query: "Kindle Book", ids: [ 2 ])
    stub_detail_feed(
      2,
      title: "Kindle Book",
      author: "Writer, Test",
      language: "en",
      links: [
        { type: "application/x-mobipocket-ebook", title: "Kindle", href: "/ebooks/2.kf8.images" }
      ]
    )

    result = GutenbergClient.search(title: "Kindle Book").first

    assert_equal "mobi", result.file_type
    assert_equal "https://www.gutenberg.org/ebooks/2.kf8.images", result.download_url
  end

  test "search limits Project Gutenberg detail lookups" do
    SettingsService.set(:gutenberg_search_limit, 1)
    stub_search_feed(query: "Common Title", ids: [ 10, 11 ])
    stub_detail_feed(
      10,
      title: "Common Title One",
      author: "Writer, One",
      language: "en",
      links: [
        { type: "application/epub+zip", title: "EPUB3", href: "/ebooks/10.epub3.images" }
      ]
    )

    results = GutenbergClient.search(title: "Common Title")

    assert_equal [ "10" ], results.map(&:id)
    assert_not_requested :get, "https://www.gutenberg.org/ebooks/11.opds"
  end

  test "test_connection returns false on connection failure" do
    stub_request(:get, "https://www.gutenberg.org/ebooks/search.opds/")
      .with(query: hash_including(
        "query" => "pride prejudice"
      ))
      .to_raise(Faraday::ConnectionFailed.new("offline"))

    assert_not GutenbergClient.test_connection
  end

  test "configured URL must be an origin" do
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org/ebooks")

    assert_raises GutenbergClient::ConfigurationError do
      GutenbergClient.search(title: "test")
    end
  end

  private

  def stub_search_feed(query:, ids:)
    entries = ids.map do |id|
      <<~XML
        <entry>
          <id>https://www.gutenberg.org/ebooks/#{id}.opds</id>
          <title>Book #{id}</title>
          <content type="text">Author #{id}</content>
          <link type="application/atom+xml;profile=opds-catalog" rel="subsection" href="/ebooks/#{id}.opds"/>
        </entry>
      XML
    end.join

    stub_request(:get, "https://www.gutenberg.org/ebooks/search.opds/")
      .with(query: hash_including("query" => query))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/atom+xml; charset=UTF-8" },
        body: opds_feed(entries)
      )
  end

  def stub_detail_feed(id, title:, author:, language:, links:)
    link_xml = links.map do |link|
      attrs = link.map { |key, value| %(#{key}="#{ERB::Util.html_escape(value)}") }.join(" ")
      %(<link rel="http://opds-spec.org/acquisition" #{attrs}/>)
    end.join("\n")

    entry = <<~XML
      <entry>
        <id>urn:gutenberg:#{id}:3</id>
        <title>#{ERB::Util.html_escape(title)}</title>
        <author><name>#{ERB::Util.html_escape(author)}</name></author>
        <dcterms:language>#{language}</dcterms:language>
        #{link_xml}
      </entry>
    XML

    stub_request(:get, "https://www.gutenberg.org/ebooks/#{id}.opds")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/atom+xml; charset=UTF-8" },
        body: opds_feed(entry)
      )
  end

  def opds_feed(entries)
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom"
            xmlns:opds="http://opds-spec.org/2010/catalog"
            xmlns:dcterms="http://purl.org/dc/terms/">
        <id>https://www.gutenberg.org/ebooks/search.opds/</id>
        <title>Project Gutenberg</title>
        #{entries}
      </feed>
    XML
  end
end
