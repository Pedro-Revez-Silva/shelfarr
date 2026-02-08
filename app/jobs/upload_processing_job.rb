# frozen_string_literal: true

# Processes uploaded files:
# 1. Extracts metadata from file (ID3 tags, EPUB OPF, etc.)
# 2. Falls back to filename parsing if extraction fails
# 3. Searches metadata sources (Hardcover/OpenLibrary) for enrichment
# 4. Creates book with proper metadata
# 5. Renames file and moves to library location
class UploadProcessingJob < ApplicationJob
  queue_as :default

  def perform(upload_id)
    upload = Upload.find_by(id: upload_id)
    return unless upload&.pending?

    Rails.logger.info "[UploadProcessingJob] Processing upload #{upload.id}: #{upload.original_filename}"

    upload.update!(status: :processing)

    begin
      # Step 1: Extract metadata from the actual file
      extracted = MetadataExtractorService.extract(upload.file_path)

      if extracted.present?
        Rails.logger.info "[UploadProcessingJob] Extracted from file: title='#{extracted.title}', author='#{extracted.author}'"
      end

      # Step 2: Parse filename as fallback
      parsed = FilenameParserService.parse(upload.original_filename)
      Rails.logger.info "[UploadProcessingJob] Parsed from filename: title='#{parsed.title}', author='#{parsed.author}'"

      # Use extracted metadata if available, otherwise fall back to parsed filename
      title = extracted.title.presence || parsed.title
      author = extracted.author.presence || parsed.author

      upload.update!(
        parsed_title: title,
        parsed_author: author,
        match_confidence: extracted.present? ? 90 : parsed.confidence
      )

      # Step 3: Determine book type from file extension
      book_type = upload.infer_book_type
      upload.update!(book_type: book_type)

      # Step 4: Search metadata sources for enrichment
      metadata = fetch_metadata(title, author)

      if metadata
        Rails.logger.info "[UploadProcessingJob] Found metadata from #{metadata.source}: '#{metadata.title}' by #{metadata.author}"
      else
        Rails.logger.info "[UploadProcessingJob] No metadata match, using extracted/parsed data"
      end

      # Wrap critical operations in transaction for atomicity
      book = nil
      destination = nil

      ActiveRecord::Base.transaction do
        # Step 5: Find or create book with metadata
        book = find_or_create_book_with_metadata(
          metadata: metadata,
          extracted: extracted,
          parsed: parsed,
          book_type: book_type
        )

        upload.update!(book: book)
        Rails.logger.info "[UploadProcessingJob] Associated with book #{book.id}: #{book.display_name}"

        # Step 6: Move and rename file to library location
        destination = move_to_library(upload, book)

        # Step 7: Update book with file path
        book.update!(file_path: destination)

        upload.update!(
          status: :completed,
          processed_at: Time.current
        )
      end

      # Step 8: Trigger Audiobookshelf scan if configured (outside transaction)
      trigger_library_scan(book) if book && AudiobookshelfClient.configured?

      Rails.logger.info "[UploadProcessingJob] Completed processing upload #{upload.id}"

    rescue => e
      Rails.logger.error "[UploadProcessingJob] Failed for upload #{upload.id}: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")

      upload.update!(
        status: :failed,
        error_message: e.message
      )
    end
  end

  private

  # Search metadata sources and return the best matching result
  def fetch_metadata(title, author)
    return nil if title.blank?

    # Build search query - include author if available for better results
    query = author.present? ? "#{title} #{author}" : title

    results = MetadataService.search(query, limit: 5)
    return nil if results.empty?

    # Score results and pick the best match
    best_match = results.max_by { |r| score_result(r, title, author) }

    # Only return if score is reasonable
    score = score_result(best_match, title, author)
    score >= 30 ? best_match : nil
  rescue HardcoverClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
    Rails.logger.warn "[UploadProcessingJob] Metadata search failed: #{e.message}"
    nil
  end

  # Score how well a search result matches the parsed title/author
  def score_result(result, query_title, query_author)
    score = 0

    # Title similarity (max 60 points)
    if result.title.present? && query_title.present?
      title_sim = string_similarity(result.title.downcase, query_title.downcase)
      score += (title_sim * 0.6).round
    end

    # Author similarity (max 40 points)
    if result.author.present? && query_author.present?
      author_sim = string_similarity(result.author.downcase, query_author.downcase)
      score += (author_sim * 0.4).round
    elsif result.author.present?
      # Bonus for having an author even if we didn't parse one
      score += 10
    end

    score
  end

  def string_similarity(str1, str2)
    return 100 if str1 == str2
    return 0 if str1.blank? || str2.blank?

    # Simple trigram similarity
    trigrams1 = to_trigrams(str1)
    trigrams2 = to_trigrams(str2)
    return 0 if trigrams1.empty? || trigrams2.empty?

    intersection = (trigrams1 & trigrams2).size
    union = (trigrams1 | trigrams2).size
    ((intersection.to_f / union) * 100).round
  end

  def to_trigrams(str)
    padded = "  #{str}  "
    (0..padded.length - 3).map { |i| padded[i, 3] }.to_set
  end

  def find_or_create_book_with_metadata(metadata:, extracted:, parsed:, book_type:)
    # Priority: online metadata > extracted file metadata > parsed filename
    title = metadata&.title || extracted&.title || parsed.title
    author = metadata&.author || extracted&.author || parsed.author
    work_id = metadata&.work_id
    cover_url = metadata&.cover_url
    year = metadata&.year || extracted&.year
    description = metadata&.description || extracted&.description
    series = metadata&.series_name if metadata.respond_to?(:series_name)
    narrator = extracted&.narrator if extracted.respond_to?(:narrator)

    # Check for existing book with same work_id and type
    if work_id.present?
      existing = Book.find_by_work_id(work_id, book_type: book_type)
      return existing if existing
    end

    # Try to match against existing books
    result = BookMatcherService.match(title: title, author: author, book_type: book_type)
    return result.book if result.exact? || result.fuzzy?

    # Create new book with metadata
    if work_id.present?
      source, _source_id = Book.parse_work_id(work_id)
      book = Book.find_or_initialize_by_work_id(work_id, book_type: book_type)
      book.assign_attributes(
        title: title,
        author: author,
        cover_url: cover_url,
        year: year,
        description: description,
        series: series,
        narrator: narrator,
        metadata_source: source
      )
      book.save!
      book
    else
      Book.create!(
        title: title,
        author: author,
        book_type: book_type,
        cover_url: cover_url,
        year: year,
        description: description,
        series: series,
        narrator: narrator
      )
    end
  end

  def move_to_library(upload, book)
    source_path = upload.file_path

    unless File.exist?(source_path)
      raise "Source file not found: #{source_path}"
    end

    destination_dir = build_destination_path(book)
    FileUtils.mkdir_p(destination_dir)

    # Rename file to standardized format: "Author - Title.ext"
    extension = File.extname(upload.original_filename)
    new_filename = build_filename(book, extension)
    destination_file = File.join(destination_dir, new_filename)

    # Handle duplicate filenames
    destination_file = handle_duplicate_filename(destination_file) if File.exist?(destination_file)

    Rails.logger.info "[UploadProcessingJob] Moving to: #{destination_file}"

    # Move file (or copy if across filesystems)
    begin
      FileUtils.mv(source_path, destination_file)
    rescue Errno::EXDEV
      # Cross-device move, use copy then delete
      FileCopyService.cp(source_path, destination_file)
      FileUtils.rm(source_path)
    end

    destination_dir
  end

  def build_filename(book, extension)
    PathTemplateService.build_filename(book, extension)
  end

  def handle_duplicate_filename(path)
    dir = File.dirname(path)
    ext = File.extname(path)
    base = File.basename(path, ext)

    counter = 1
    new_path = path
    while File.exist?(new_path)
      counter += 1
      new_path = File.join(dir, "#{base} (#{counter})#{ext}")
    end
    new_path
  end

  def build_destination_path(book)
    PathTemplateService.build_destination(book)
  end

  def get_base_path(book)
    if book.audiobook?
      SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    else
      SettingsService.get(:ebook_output_path, default: "/ebooks")
    end
  end

  def sanitize_filename(name)
    name
      .gsub(/[<>:"\/\\|?*]/, "")
      .gsub(/[\x00-\x1f]/, "")
      .strip
      .gsub(/\s+/, " ")
      .truncate(100, omission: "")
  end

  def trigger_library_scan(book)
    library_id = if book.audiobook?
      SettingsService.get(:audiobookshelf_audiobook_library_id)
    else
      SettingsService.get(:audiobookshelf_ebook_library_id)
    end

    return unless library_id.present?

    AudiobookshelfClient.scan_library(library_id)
    Rails.logger.info "[UploadProcessingJob] Triggered Audiobookshelf library scan for #{book.book_type}"
  rescue AudiobookshelfClient::Error => e
    Rails.logger.warn "[UploadProcessingJob] Failed to trigger scan: #{e.message}"
  end
end
