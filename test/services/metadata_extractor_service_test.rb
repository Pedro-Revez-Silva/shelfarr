# frozen_string_literal: true

require "test_helper"

class MetadataExtractorServiceTest < ActiveSupport::TestCase
  test "returns empty result for non-existent file" do
    result = MetadataExtractorService.extract("/nonexistent/file.mp3")

    assert_not result.success
    assert_nil result.title
    assert_nil result.author
  end

  test "returns empty result for unsupported file type" do
    # Create a temp file with unsupported extension
    file = Tempfile.new(["test", ".txt"])
    file.write("Hello world")
    file.close

    result = MetadataExtractorService.extract(file.path)

    assert_not result.success
    assert_nil result.title
  ensure
    file.unlink
  end

  test "Result.empty returns unsuccessful result with nil fields" do
    result = MetadataExtractorService::Result.empty

    assert_not result.success
    assert_nil result.title
    assert_nil result.author
    assert_nil result.year
    assert_nil result.description
    assert_nil result.narrator
  end

  test "Result.present? returns true when title is present" do
    result = MetadataExtractorService::Result.new(
      title: "Test Book",
      author: nil,
      year: nil,
      description: nil,
      narrator: nil,
      success: true
    )

    assert result.present?
  end

  test "Result.present? returns true when author is present" do
    result = MetadataExtractorService::Result.new(
      title: nil,
      author: "Test Author",
      year: nil,
      description: nil,
      narrator: nil,
      success: true
    )

    assert result.present?
  end

  test "Result.present? returns false when both title and author are nil" do
    result = MetadataExtractorService::Result.new(
      title: nil,
      author: nil,
      year: 2020,
      description: "Description",
      narrator: nil,
      success: false
    )

    assert_not result.present?
  end

  test "extracts metadata from EPUB file" do
    # Create a minimal EPUB file structure
    epub_path = create_test_epub(
      title: "The Great Gatsby",
      author: "F. Scott Fitzgerald",
      date: "1925"
    )

    result = MetadataExtractorService.extract(epub_path)

    assert result.success
    assert_equal "The Great Gatsby", result.title
    assert_equal "F. Scott Fitzgerald", result.author
    assert_equal 1925, result.year
  ensure
    File.delete(epub_path) if epub_path && File.exist?(epub_path)
  end

  test "handles EPUB without metadata gracefully" do
    # Create an EPUB with missing metadata
    epub_path = create_test_epub(title: nil, author: nil, date: nil)

    result = MetadataExtractorService.extract(epub_path)

    # Should return empty result without crashing
    assert_not result.success
  ensure
    File.delete(epub_path) if epub_path && File.exist?(epub_path)
  end

  private

  def create_test_epub(title:, author:, date:)
    require "zip"

    path = Rails.root.join("tmp", "test_#{SecureRandom.hex(4)}.epub").to_s

    Zip::File.open(path, create: true) do |zipfile|
      # Add mimetype (must be first and uncompressed)
      zipfile.get_output_stream("mimetype") { |f| f.write "application/epub+zip" }

      # Add container.xml
      container_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
      XML
      zipfile.get_output_stream("META-INF/container.xml") { |f| f.write container_xml }

      # Add content.opf with metadata
      opf_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            #{title ? "<dc:title>#{title}</dc:title>" : ""}
            #{author ? "<dc:creator>#{author}</dc:creator>" : ""}
            #{date ? "<dc:date>#{date}</dc:date>" : ""}
          </metadata>
          <manifest></manifest>
          <spine></spine>
        </package>
      XML
      zipfile.get_output_stream("OEBPS/content.opf") { |f| f.write opf_xml }
    end

    path
  end
end
