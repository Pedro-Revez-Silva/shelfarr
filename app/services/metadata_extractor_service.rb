# frozen_string_literal: true

# Extracts metadata from uploaded files (audiobooks and ebooks)
# Reads embedded metadata like ID3 tags, EPUB OPF, PDF info, etc.
class MetadataExtractorService
  MP4_ATOM_HEADER_SIZE = 8
  MP4_EXTENDED_ATOM_HEADER_SIZE = 16
  MAX_MP4_METADATA_ATOM_SIZE = 1024 * 1024
  MAX_MP4_INSPECTED_ATOMS = 4096
  MAX_MP4_METADATA_BYTES = 4 * 1024 * 1024
  MAX_EPUB_ENTRIES = 10_000
  MAX_EPUB_METADATA_ENTRY_BYTES = 2.megabytes
  MAX_EPUB_CENTRAL_DIRECTORY_BYTES = 16.megabytes
  MAX_EPUB_METADATA_PATH_BYTES = 4_096
  MAX_ID3_TAG_BYTES = 4.megabytes
  MAX_PDF_METADATA_FILE_BYTES = 32.megabytes
  MAX_METADATA_NAME_BYTES = 1_024
  MAX_METADATA_DESCRIPTION_BYTES = 64.kilobytes
  MAX_METADATA_YEAR_BYTES = 128
  MAX_METADATA_ARRAY_VALUES = 16
  MAX_METADATA_INPUT_FACTOR = 4
  MP4_METADATA_ATOMS = {
    "\xA9nam".b => :title,
    "\xA9ART".b => :artist,
    "\xA9alb".b => :album,
    "aART".b => :album_artist,
    "\xA9day".b => :year,
    "desc".b => :description,
    "\xA9wrt".b => :narrator
  }.freeze

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
      return Result.empty if file_path.blank?

      File.open(file_path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        return Result.empty unless file.stat.file?

        extract_io(file, filename: File.basename(file_path))
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENXIO, Errno::ENODEV, Errno::ENOTDIR => error
      Rails.logger.warn "[MetadataExtractorService] Metadata source is not safely accessible (#{error.class})"
      Result.empty
    rescue => error
      Rails.logger.warn "[MetadataExtractorService] Failed to open metadata source (#{error.class})"
      Result.empty
    end

    # Extract from one already-open regular-file descriptor. Every parser uses
    # this same descriptor, so a same-path replacement cannot turn validation
    # into a blocking FIFO open or redirect a later parser read.
    def extract_io(file, filename:)
      return Result.empty unless file.stat.file?

      extension = File.extname(filename.to_s).downcase.delete(".")
      extension = "unknown" unless extension.match?(/\A[a-z0-9]{1,10}\z/)
      file.rewind
      result = case extension
      when "mp3"
        extract_mp3_io(file)
      when "m4b", "m4a", "aax", "aaxc"
        extract_m4b_io(file)
      when "epub"
        extract_epub_io(file)
      when "pdf"
        extract_pdf_io(file)
      else
        Result.empty
      end

      Rails.logger.info "[MetadataExtractorService] Inspected #{extension} metadata (present=#{result.present?})"
      result
    rescue => error
      Rails.logger.warn(
        "[MetadataExtractorService] Failed to extract #{extension.presence || 'unknown'} metadata " \
          "(#{error.class})"
      )
      Result.empty
    end

    private

    # Extract metadata from MP3 files using ID3 tags
    def extract_mp3(file_path)
      File.open(file_path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        extract_mp3_io(file)
      end
    end

    def extract_mp3_io(file)
      require "id3tag"

      ID3Tag.local_configuration do |configuration|
        configuration.v2_tag_read_limit = MAX_ID3_TAG_BYTES
        tag = ID3Tag.read(file)

        # For audiobooks, the album is often the book title
        # and artist is the author. id3tag parses lazily, so every accessor must
        # stay inside the bounded local-configuration scope.
        title = tag.title.presence || tag.album.presence
        author = tag.artist.presence
        cleaned_title = clean_string(title)
        cleaned_author = clean_string(author)

        # Try to get year from various ID3 frames
        year = parse_year(tag.year) || parse_year(tag.get_frame(:TDRC)&.content)

        Result.new(
          title: cleaned_title,
          author: cleaned_author,
          year: year,
          description: nil,
          narrator: nil,
          success: cleaned_title.present? || cleaned_author.present?
        )
      end
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] MP3 extraction failed (#{e.class})"
      Result.empty
    end

    # Extract metadata from M4B/M4A files (AAC audiobooks)
    # M4B files are MP4 containers - we parse the atoms manually
    def extract_m4b(file_path)
      File.open(file_path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        extract_m4b_io(file)
      end
    end

    def extract_m4b_io(file)
      metadata = parse_mp4_atoms(file)
      title = clean_string(metadata[:title].presence || metadata[:album])
      author = clean_string(metadata[:artist].presence || metadata[:album_artist])

      Result.new(
        title: title,
        author: author,
        year: parse_year(metadata[:year]),
        description: clean_string(metadata[:description], max_bytes: MAX_METADATA_DESCRIPTION_BYTES),
        narrator: clean_string(metadata[:narrator]),
        success: title.present? || author.present?
      )
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] M4B extraction failed (#{e.class})"
      Result.empty
    end

    # Extract metadata from EPUB files
    # EPUB is a ZIP archive with OPF metadata file
    def extract_epub(file_path)
      File.open(file_path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        extract_epub_io(file)
      end
    end

    def extract_epub_io(file)
      require "zip"
      require "nokogiri"

      file.rewind
      ZipArchivePreflightService.validate!(
        file,
        max_entries: MAX_EPUB_ENTRIES,
        max_central_directory_bytes: MAX_EPUB_CENTRAL_DIRECTORY_BYTES
      )
      extracted = nil
      Zip::File.open_buffer(file) do |zip|
        return Result.empty if zip.entries.length > MAX_EPUB_ENTRIES

        # Find the OPF file from container.xml
        container = zip.find_entry("META-INF/container.xml")
        return Result.empty unless container

        container_doc = Nokogiri::XML(read_zip_entry_capped(container)) { |config| config.nonet }
        opf_path = container_doc.at_xpath("//xmlns:rootfile/@full-path")&.value
        return Result.empty unless opf_path
        return Result.empty if opf_path.bytesize > MAX_EPUB_METADATA_PATH_BYTES

        # Read the OPF file
        opf_entry = zip.find_entry(opf_path)
        return Result.empty unless opf_entry

        opf_doc = Nokogiri::XML(read_zip_entry_capped(opf_entry)) { |config| config.nonet }
        opf_doc.remove_namespaces!

        # Extract metadata from OPF
        title = opf_doc.at_xpath("//metadata/title")&.text
        author = opf_doc.at_xpath("//metadata/creator")&.text
        description = opf_doc.at_xpath("//metadata/description")&.text
        date = opf_doc.at_xpath("//metadata/date")&.text
        cleaned_title = clean_string(title)
        cleaned_author = clean_string(author)

        extracted = Result.new(
          title: cleaned_title,
          author: cleaned_author,
          year: parse_year(date),
          description: clean_string(description, max_bytes: MAX_METADATA_DESCRIPTION_BYTES),
          narrator: nil,
          success: cleaned_title.present? || cleaned_author.present?
        )
      end
      extracted || Result.empty
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] EPUB extraction failed (#{e.class})"
      Result.empty
    end

    def read_zip_entry_capped(entry)
      return "" if entry.size.negative? || entry.size > MAX_EPUB_METADATA_ENTRY_BYTES

      value = entry.get_input_stream.read(MAX_EPUB_METADATA_ENTRY_BYTES + 1).to_s
      raise Zip::Error, "EPUB metadata entry is too large" if value.bytesize > MAX_EPUB_METADATA_ENTRY_BYTES

      value
    end

    # Extract metadata from PDF files
    def extract_pdf(file_path)
      File.open(file_path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        extract_pdf_io(file)
      end
    end

    def extract_pdf_io(file)
      return Result.empty unless file.respond_to?(:stat) && file.stat.file?
      return Result.empty if file.stat.size > MAX_PDF_METADATA_FILE_BYTES

      # pdf-reader inflates xref, object, and Info streams without an output or
      # object-count limit. A tiny user-controlled PDF can therefore expand far
      # beyond any input-size ceiling before `reader.info` returns. Keep PDF
      # metadata on the safe filename-fallback path until it can run inside a
      # resource-limited subprocess; never parse it in the Puma/job process.
      Result.empty
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] PDF extraction failed (#{e.class})"
      Result.empty
    end

    # Parse MP4/M4B atoms to extract metadata
    # MP4 files use a tree of "atoms" (boxes) to store data
    def parse_mp4_atoms(file)
      metadata = {}
      budget = { atoms: 0, metadata_bytes: 0 }

      parse_mp4_atom_range(file, file.size, metadata, budget, context: :root)

      metadata
    rescue => e
      Rails.logger.debug "[MetadataExtractorService] MP4 parsing error (#{e.class})"
      {}
    end

    def parse_mp4_atom_range(file, range_end, metadata, budget, context:)
      while file.pos + MP4_ATOM_HEADER_SIZE <= range_end && budget[:atoms] < MAX_MP4_INSPECTED_ATOMS
        atom = read_mp4_atom_header(file, range_end)
        break unless atom

        budget[:atoms] += 1

        begin
          parse_mp4_atom(file, atom, metadata, budget, context: context)
        ensure
          file.seek(atom[:end], IO::SEEK_SET) unless file.pos == atom[:end]
        end
      end
    end

    def parse_mp4_atom(file, atom, metadata, budget, context:)
      case context
      when :root
        parse_mp4_atom_range(file, atom[:end], metadata, budget, context: :moov) if atom[:type] == "moov".b
      when :moov
        if atom[:type] == "udta".b
          parse_mp4_atom_range(file, atom[:end], metadata, budget, context: :udta)
        elsif atom[:type] == "meta".b
          parse_mp4_meta_atom(file, atom, metadata, budget)
        end
      when :udta
        if atom[:type] == "meta".b
          parse_mp4_meta_atom(file, atom, metadata, budget)
        elsif atom[:type] == "ilst".b
          parse_mp4_atom_range(file, atom[:end], metadata, budget, context: :ilst)
        end
      when :meta
        parse_mp4_atom_range(file, atom[:end], metadata, budget, context: :ilst) if atom[:type] == "ilst".b
      when :ilst
        parse_mp4_metadata_atom(file, atom, metadata, budget)
      end
    end

    def parse_mp4_meta_atom(file, atom, metadata, budget)
      return if atom[:payload_size] < 4

      file.seek(4, IO::SEEK_CUR) # version and flags
      parse_mp4_atom_range(file, atom[:end], metadata, budget, context: :meta)
    end

    def parse_mp4_metadata_atom(file, atom, metadata, budget)
      field = MP4_METADATA_ATOMS[atom[:type]]
      return unless field
      return if metadata.key?(field)

      value = read_mp4_data_atom(file, atom[:payload_size], budget: budget)
      metadata[field] = value if value.present?
    end

    def read_mp4_atom_header(file, range_end)
      atom_start = file.pos
      header = file.read(MP4_ATOM_HEADER_SIZE)
      return unless header&.bytesize == MP4_ATOM_HEADER_SIZE

      atom_size = header.byteslice(0, 4).unpack1("N")
      type = header.byteslice(4, 4)
      header_size = MP4_ATOM_HEADER_SIZE

      if atom_size == 1
        return if file.pos + 8 > range_end

        extended_size = file.read(8)
        return unless extended_size&.bytesize == 8

        atom_size = extended_size.unpack1("Q>")
        header_size = MP4_EXTENDED_ATOM_HEADER_SIZE
      elsif atom_size == 0
        atom_size = range_end - atom_start
      end

      return if atom_size < header_size

      atom_end = atom_start + atom_size
      return if atom_end > range_end

      {
        type: type,
        end: atom_end,
        payload_size: atom_end - file.pos
      }
    end

    # Read a data atom value from MP4 file
    def read_mp4_data_atom(file, size, budget: nil)
      return nil if size.negative?

      item_end = file.pos + size
      return nil if item_end > file.size
      return nil if size < 16 || size > MAX_MP4_METADATA_ATOM_SIZE

      # Nested data atom: size(4), "data"(4), type(4), locale(4), value.
      data_header = file.read(16)
      return nil unless data_header&.bytesize == 16
      return nil unless data_header.byteslice(4, 4) == "data"

      data_size = data_header.byteslice(0, 4).unpack1("N")
      data_size = size if data_size.zero?
      return nil if data_size < 16 || data_size > size

      value_size = data_size - 16
      return nil if budget && budget[:metadata_bytes] + value_size > MAX_MP4_METADATA_BYTES

      value = file.read(value_size)
      return nil unless value&.bytesize == value_size

      budget[:metadata_bytes] += value_size if budget
      value.force_encoding("UTF-8").scrub
    ensure
      if defined?(item_end) && item_end
        file.seek([ item_end, file.size ].min, IO::SEEK_SET)
      end
    end

    # Parse year from various date formats
    def parse_year(value)
      str = clean_string(value, max_bytes: MAX_METADATA_YEAR_BYTES)
      return nil if str.blank?

      # Match 4-digit year (1900-2099)
      match = str.match(/\b(19\d{2}|20\d{2})\b/)
      match ? match[1].to_i : nil
    end

    # Clean up extracted string values
    def clean_string(value, max_bytes: MAX_METADATA_NAME_BYTES)
      max_bytes = Integer(max_bytes)
      return nil unless max_bytes.positive?

      values = value.is_a?(Array) ? value.first(MAX_METADATA_ARRAY_VALUES) : [ value ]
      cleaned = +""
      values.each do |item|
        component = clean_metadata_component(item, max_bytes)
        next if component.blank?

        separator = cleaned.empty? ? "" : "; "
        remaining = max_bytes - cleaned.bytesize - separator.bytesize
        break unless remaining.positive?

        cleaned << separator
        cleaned << component.byteslice(0, remaining).to_s.scrub("")
      end
      cleaned.strip.presence
    rescue RangeError, TypeError, ArgumentError
      nil
    end

    def clean_metadata_component(value, max_bytes)
      return nil unless value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Numeric)

      raw = value.to_s
      input_limit = max_bytes * MAX_METADATA_INPUT_FACTOR
      raw = raw.byteslice(0, input_limit) if raw.bytesize > input_limit
      raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
    end
  end
end
