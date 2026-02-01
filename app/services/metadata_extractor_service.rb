# frozen_string_literal: true

# Extracts metadata from uploaded files (audiobooks and ebooks)
# Reads embedded metadata like ID3 tags, EPUB OPF, PDF info, etc.
class MetadataExtractorService
  # Result of metadata extraction
  Result = Data.define(:title, :author, :year, :description, :narrator, :success) do
    def self.empty
      new(title: nil, author: nil, year: nil, description: nil, narrator: nil, success: false)
    end

    def present?
      title.present? || author.present?
    end
  end

  class << self
    # Extract metadata from a file
    # Returns a Result with extracted metadata
    def extract(file_path)
      return Result.empty unless File.exist?(file_path)

      extension = File.extname(file_path).downcase.delete(".")

      result = case extension
      when "mp3"
        extract_mp3(file_path)
      when "m4b", "m4a"
        extract_m4b(file_path)
      when "epub"
        extract_epub(file_path)
      when "pdf"
        extract_pdf(file_path)
      else
        Result.empty
      end

      Rails.logger.info "[MetadataExtractorService] Extracted from #{extension}: title='#{result.title}', author='#{result.author}'"
      result
    rescue => e
      Rails.logger.warn "[MetadataExtractorService] Failed to extract from #{file_path}: #{e.message}"
      Result.empty
    end

    private

    # Extract metadata from MP3 files using ID3 tags
    def extract_mp3(file_path)
      require "id3tag"

      File.open(file_path, "rb") do |file|
        tag = ID3Tag.read(file)

        # For audiobooks, the album is often the book title
        # and artist is the author
        title = tag.title.presence || tag.album.presence
        author = tag.artist.presence

        # Try to get year from various ID3 frames
        year = parse_year(tag.year) || parse_year(tag.get_frame(:TDRC)&.content)

        Result.new(
          title: clean_string(title),
          author: clean_string(author),
          year: year,
          description: nil,
          narrator: nil,
          success: title.present? || author.present?
        )
      end
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] MP3 extraction failed: #{e.message}"
      Result.empty
    end

    # Extract metadata from M4B/M4A files (AAC audiobooks)
    # M4B files are MP4 containers - we parse the atoms manually
    def extract_m4b(file_path)
      File.open(file_path, "rb") do |file|
        metadata = parse_mp4_atoms(file)

        Result.new(
          title: clean_string(metadata[:title] || metadata[:album]),
          author: clean_string(metadata[:artist] || metadata[:album_artist]),
          year: parse_year(metadata[:year]),
          description: clean_string(metadata[:description]),
          narrator: clean_string(metadata[:narrator]),
          success: metadata[:title].present? || metadata[:artist].present?
        )
      end
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] M4B extraction failed: #{e.message}"
      Result.empty
    end

    # Extract metadata from EPUB files
    # EPUB is a ZIP archive with OPF metadata file
    def extract_epub(file_path)
      require "zip"
      require "nokogiri"

      Zip::File.open(file_path) do |zip|
        # Find the OPF file from container.xml
        container = zip.find_entry("META-INF/container.xml")
        return Result.empty unless container

        container_doc = Nokogiri::XML(container.get_input_stream.read)
        opf_path = container_doc.at_xpath("//xmlns:rootfile/@full-path")&.value
        return Result.empty unless opf_path

        # Read the OPF file
        opf_entry = zip.find_entry(opf_path)
        return Result.empty unless opf_entry

        opf_doc = Nokogiri::XML(opf_entry.get_input_stream.read)
        opf_doc.remove_namespaces!

        # Extract metadata from OPF
        title = opf_doc.at_xpath("//metadata/title")&.text
        author = opf_doc.at_xpath("//metadata/creator")&.text
        description = opf_doc.at_xpath("//metadata/description")&.text
        date = opf_doc.at_xpath("//metadata/date")&.text

        Result.new(
          title: clean_string(title),
          author: clean_string(author),
          year: parse_year(date),
          description: clean_string(description),
          narrator: nil,
          success: title.present? || author.present?
        )
      end
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] EPUB extraction failed: #{e.message}"
      Result.empty
    end

    # Extract metadata from PDF files
    def extract_pdf(file_path)
      require "pdf-reader"

      reader = PDF::Reader.new(file_path)
      info = reader.info || {}

      title = info[:Title]
      author = info[:Author]
      # PDF creation date format: D:YYYYMMDDHHmmSS
      year = parse_year(info[:CreationDate])

      Result.new(
        title: clean_string(title),
        author: clean_string(author),
        year: year,
        description: nil,
        narrator: nil,
        success: title.present? || author.present?
      )
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] PDF extraction failed: #{e.message}"
      Result.empty
    end

    # Parse MP4/M4B atoms to extract metadata
    # MP4 files use a tree of "atoms" (boxes) to store data
    def parse_mp4_atoms(file)
      metadata = {}

      # Read atoms until we find moov > udta > meta > ilst
      while !file.eof?
        atom_header = file.read(8)
        break if atom_header.nil? || atom_header.length < 8

        size = atom_header[0, 4].unpack1("N")
        type = atom_header[4, 4]

        # Handle extended size
        if size == 1
          size = file.read(8).unpack1("Q>")
          size -= 16
        elsif size == 0
          # Atom extends to end of file
          break
        else
          size -= 8
        end

        case type
        when "moov", "udta", "meta", "ilst"
          # Container atoms - skip 4 bytes for meta (version/flags)
          file.read(4) if type == "meta"
          # Continue parsing inside these containers
          next
        when "\xA9nam" # Title
          metadata[:title] = read_mp4_data_atom(file, size)
        when "\xA9ART" # Artist
          metadata[:artist] = read_mp4_data_atom(file, size)
        when "\xA9alb" # Album
          metadata[:album] = read_mp4_data_atom(file, size)
        when "aART" # Album artist
          metadata[:album_artist] = read_mp4_data_atom(file, size)
        when "\xA9day" # Year
          metadata[:year] = read_mp4_data_atom(file, size)
        when "desc" # Description
          metadata[:description] = read_mp4_data_atom(file, size)
        when "\xA9wrt" # Narrator (sometimes stored as composer)
          metadata[:narrator] = read_mp4_data_atom(file, size)
        else
          # Skip unknown atoms
          file.seek(size, IO::SEEK_CUR) if size > 0
        end

        # Safety check - don't read past end of file
        break if file.pos >= file.size
      end

      metadata
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] MP4 parsing error: #{e.message}"
      {}
    end

    # Read a data atom value from MP4 file
    def read_mp4_data_atom(file, size)
      return nil if size < 16

      # Data atom structure: size(4) + "data"(4) + type(4) + locale(4) + value
      data_header = file.read(16)
      return nil unless data_header && data_header.length == 16

      remaining = size - 16
      return nil if remaining <= 0

      value = file.read(remaining)
      value&.force_encoding("UTF-8")&.scrub
    end

    # Parse year from various date formats
    def parse_year(value)
      return nil if value.blank?

      str = value.to_s
      # Match 4-digit year (1900-2099)
      match = str.match(/\b(19\d{2}|20\d{2})\b/)
      match ? match[1].to_i : nil
    end

    # Clean up extracted string values
    def clean_string(value)
      return nil if value.blank?

      value.to_s
           .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
           .strip
           .presence
    end
  end
end
