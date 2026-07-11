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
    file = Tempfile.new([ "test", ".txt" ])
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

  test "extracts metadata from PDF info" do
    require "pdf-reader"
    fake_reader = Struct.new(:info).new(
      {
        Title: "PDF Book",
        Author: "PDF Author",
        CreationDate: "created 2024"
      }
    )

    PDF::Reader.stub(:new, fake_reader) do
      result = MetadataExtractorService.send(:extract_pdf, "book.pdf")

      assert result.success
      assert_equal "PDF Book", result.title
      assert_equal "PDF Author", result.author
      assert_equal 2024, result.year
    end
  end

  test "parses MP4 metadata atoms" do
    file = StringIO.new(
      mp4_metadata_file(
        mp4_atom([ 0xA9 ].pack("C") + "nam", "M4B Title") +
        mp4_atom([ 0xA9 ].pack("C") + "ART", "M4B Author") +
        mp4_atom([ 0xA9 ].pack("C") + "alb", "M4B Album") +
        mp4_atom("aART", "Album Author") +
        mp4_atom([ 0xA9 ].pack("C") + "day", "2020") +
        mp4_atom("desc", "Description") +
        mp4_atom([ 0xA9 ].pack("C") + "wrt", "Narrator")
      )
    )
    file.set_encoding(Encoding::BINARY)

    metadata = MetadataExtractorService.send(:parse_mp4_atoms, file)

    assert_equal "M4B Title", metadata[:title]
    assert_equal "M4B Author", metadata[:artist]
    assert_equal "M4B Album", metadata[:album]
    assert_equal "Album Author", metadata[:album_artist]
    assert_equal "2020", metadata[:year]
    assert_equal "Description", metadata[:description]
    assert_equal "Narrator", metadata[:narrator]
  end

  test "extracts m4b metadata from parsed atoms" do
    Tempfile.create([ "book", ".m4b" ]) do |file|
      file.binmode
      file.write(
        mp4_metadata_file(
          mp4_atom([ 0xA9 ].pack("C") + "nam", "M4B Title") +
          mp4_atom([ 0xA9 ].pack("C") + "ART", "M4B Author")
        )
      )
      file.flush

      result = MetadataExtractorService.extract(file.path)

      assert result.success
      assert_equal "M4B Title", result.title
      assert_equal "M4B Author", result.author
    end
  end

  test "uses later MP4 fallback fields when primary fields are blank" do
    Tempfile.create([ "book", ".m4b" ]) do |file|
      file.binmode
      file.write(
        mp4_metadata_file(
          mp4_atom([ 0xA9 ].pack("C") + "nam", "  ") +
          mp4_atom([ 0xA9 ].pack("C") + "ART", "") +
          mp4_atom([ 0xA9 ].pack("C") + "alb", "Album Title") +
          mp4_atom("aART", "Album Author")
        )
      )
      file.flush

      result = MetadataExtractorService.extract(file.path)

      assert result.success
      assert_equal "Album Title", result.title
      assert_equal "Album Author", result.author
    end
  end

  test "extracts AAX metadata through the MP4 parser" do
    Tempfile.create([ "book", ".aax" ]) do |file|
      file.binmode
      file.write(
        mp4_metadata_file(
          mp4_atom([ 0xA9 ].pack("C") + "nam", "AAX Title") +
          mp4_atom([ 0xA9 ].pack("C") + "ART", "AAX Author")
        )
      )
      file.flush

      result = MetadataExtractorService.extract(file.path)

      assert result.success
      assert_equal "AAX Title", result.title
      assert_equal "AAX Author", result.author
    end
  end

  test "extracts AAXC metadata without treating it as a splittable format" do
    Tempfile.create([ "book", ".aaxc" ]) do |file|
      file.binmode
      file.write(
        mp4_metadata_file(
          mp4_atom([ 0xA9 ].pack("C") + "nam", "AAXC Title") +
          mp4_atom([ 0xA9 ].pack("C") + "ART", "AAXC Author")
        )
      )
      file.flush

      result = MetadataExtractorService.extract(file.path)

      assert result.success
      assert_equal "AAXC Title", result.title
      assert_equal "AAXC Author", result.author
    end
  end

  test "does not treat Audible AA files as MP4 containers" do
    Tempfile.create([ "book", ".aa" ]) do |file|
      file.binmode
      file.write(mp4_metadata_file(mp4_atom([ 0xA9 ].pack("C") + "nam", "Not AA Metadata")))
      file.flush

      result = MetadataExtractorService.extract(file.path)

      assert_not result.success
      assert_nil result.title
    end
  end

  test "stops parsing when an MP4 atom is smaller than its header" do
    file = StringIO.new(([ 4 ].pack("N") + "free" + ("x" * 1024)).b)

    metadata = MetadataExtractorService.send(:parse_mp4_atoms, file)

    assert_empty metadata
    assert_equal 8, file.pos
  end

  test "stops parsing when an MP4 atom exceeds the remaining file" do
    file = StringIO.new(([ 4096 ].pack("N") + "free" + "short").b)

    metadata = MetadataExtractorService.send(:parse_mp4_atoms, file)

    assert_empty metadata
    assert_equal 8, file.pos
  end

  test "ignores metadata atoms outside the MP4 metadata hierarchy" do
    file = StringIO.new(mp4_atom([ 0xA9 ].pack("C") + "nam", "Top-level Title"))
    file.set_encoding(Encoding::BINARY)

    metadata = MetadataExtractorService.send(:parse_mp4_atoms, file)

    assert_empty metadata
  end

  test "does not read a child atom past its container boundary" do
    oversized_child_header = [ 100 ].pack("N") + "udta"
    file = StringIO.new(mp4_container("moov", oversized_child_header))
    file.set_encoding(Encoding::BINARY)

    metadata = MetadataExtractorService.send(:parse_mp4_atoms, file)

    assert_empty metadata
  end

  test "does not read an extended atom size past its container boundary" do
    truncated_extended_atom = [ 1 ].pack("N") + "udta"
    file = StringIO.new(truncated_extended_atom + "outside!")

    atom = MetadataExtractorService.send(:read_mp4_atom_header, file, 8)

    assert_nil atom
    assert_equal 8, file.pos
  end

  test "limits the total number of inspected MP4 atoms" do
    padding = mp4_container("free", "") * MetadataExtractorService::MAX_MP4_INSPECTED_ATOMS
    trailing_metadata = mp4_container(
      "udta",
      mp4_container(
        "meta",
        ("\0" * 4) + mp4_container(
          "ilst",
          mp4_atom([ 0xA9 ].pack("C") + "nam", "Too Late")
        )
      )
    )
    file = StringIO.new(mp4_container("moov", padding + trailing_metadata))
    file.set_encoding(Encoding::BINARY)

    metadata = MetadataExtractorService.send(:parse_mp4_atoms, file)

    assert_empty metadata
  end

  test "skips oversized MP4 metadata values without losing later atoms" do
    oversized_payload_size = MetadataExtractorService::MAX_MP4_METADATA_ATOM_SIZE + 1
    oversized_atom = (
      [ 8 + oversized_payload_size ].pack("N") +
      [ 0xA9 ].pack("C") + "nam" +
      ("\0" * oversized_payload_size)
    ).b
    file = StringIO.new(
      mp4_metadata_file(
        oversized_atom + mp4_atom([ 0xA9 ].pack("C") + "ART", "M4B Author")
      )
    )
    file.set_encoding(Encoding::BINARY)

    metadata = MetadataExtractorService.send(:parse_mp4_atoms, file)

    assert_nil metadata[:title]
    assert_equal "M4B Author", metadata[:artist]
  end

  test "read_mp4_data_atom returns nil for invalid sizes" do
    assert_nil MetadataExtractorService.send(:read_mp4_data_atom, StringIO.new, 12)
    assert_nil MetadataExtractorService.send(:read_mp4_data_atom, StringIO.new("short"), 20)
  end

  test "parse helpers clean strings and years" do
    assert_equal 1999, MetadataExtractorService.send(:parse_year, "published 1999-01-01")
    assert_nil MetadataExtractorService.send(:parse_year, "unknown")
    assert_equal "Trimmed", MetadataExtractorService.send(:clean_string, "  Trimmed  ")
    assert_nil MetadataExtractorService.send(:clean_string, "  ")
  end

  private

  def mp4_atom(type, value)
    value = value.b
    data = [ 16 + value.bytesize ].pack("N") + "data" + ("\0" * 8).b + value
    ([ 8 + data.bytesize ].pack("N") + type.b + data).b
  end

  def mp4_metadata_file(metadata_atoms)
    ilst = mp4_container("ilst", metadata_atoms)
    meta = mp4_container("meta", ("\0" * 4) + ilst)
    udta = mp4_container("udta", meta)
    mp4_container("moov", udta)
  end

  def mp4_container(type, payload)
    payload = payload.b
    ([ 8 + payload.bytesize ].pack("N") + type.b + payload).b
  end

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
