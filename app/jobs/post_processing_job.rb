# frozen_string_literal: true

require "fiddle"

# Imports completed downloads to the library folder and triggers library scan.
# Files are copied by default to preserve seeding for torrent downloads.
# Usenet downloads are removed from the client after successful import.
class PostProcessingJob < ApplicationJob
  EBOOK_FILE_EXTENSIONS = %w[epub pdf mobi azw azw3 cbz cbr djvu].freeze
  EBOOK_SIDECAR_EXTENSIONS = %w[jpg jpeg png webp opf nfo txt].freeze
  EBOOK_ALLOWED_EXTENSIONS = (EBOOK_FILE_EXTENSIONS + EBOOK_SIDECAR_EXTENSIONS).freeze
  MAX_FILENAME_BYTES = 255
  IMPORT_TEMP_LOCK_MAGIC = "shelfarr-import-v1"
  IMPORT_TEMP_LOCK_PATTERN = /\A\.shelfarr-import-([0-9a-f]{32})\.lock\z/
  AT_FDCWD = -100
  LINUX_RENAME_NOREPLACE = 0x1
  DARWIN_RENAME_EXCL = 0x4

  class AtomicPublicationUnsupportedError < StandardError; end

  queue_as :default

  def perform(download_id, source_path_retry_count = 0, expected_owner_job_id = nil)
    download = Download.find_by(id: download_id)
    return unless download&.completed?

    request = download.request
    return unless claim_request_for_post_processing(download, request, expected_owner_job_id)

    book = request.book

    Rails.logger.info "[PostProcessingJob] Starting post-processing for download #{download.id} (#{book.title})"

    begin
      base_path = get_base_path(book)
      destination = build_destination_path(book, base_path: base_path)
      source_path = remap_download_path(download.download_path, download)
      if source_path_unavailable?(source_path)
        return retry_source_path_later(download, request, source_path, source_path_retry_count)
      end
      validate_download_specific_source_path!(source_path, download)

      source_cleanup = import_files(source_path, destination, book: book, base_path: base_path)
      cleanup_usenet_download(download)

      book_path = imported_book_path(book, destination)
      book.update!(file_path: book_path)
      remove_import_source(source_cleanup)

      request.complete!

      # Pre-create zip for directories (audiobooks) so download is instant.
      # Flat imports share the output root, which must never be zipped whole.
      if File.directory?(book_path) && (!PathTemplateService.flat_output?(book) || @imported_book_path_override.present?)
        pre_create_download_zip(book, book_path)
      end

      trigger_library_scan(book) if LibraryPlatformClient.configured?

      NotificationService.request_completed(request)

      Rails.logger.info "[PostProcessingJob] Completed processing for #{book.title} -> #{destination}"
    rescue => e
      Rails.logger.error "[PostProcessingJob] Failed for download #{download.id}: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      request.mark_for_attention!("Post-processing failed: #{e.message}")
    end
  end

  private

  def claim_request_for_post_processing(download, request, expected_owner_job_id)
    request.with_lock do
      download.reload
      return false unless download.completed?
      return false if request.completed?
      return false unless request.downloading? || request.processing?

      selected_result_id = request.search_results.selected.pick(:id)
      return false if download.search_result_id.present? && download.search_result_id != selected_result_id
      return false if request.downloads.active.where.not(id: download.id).exists?
      return false unless download.claim_post_processing!(job_id, expected_owner_job_id: expected_owner_job_id)

      request.update!(status: :processing) unless request.processing?
    end

    true
  end

  def source_path_unavailable?(source_path)
    source_path.present? && !File.exist?(source_path)
  end

  def validate_download_specific_source_path!(source_path, download)
    return unless source_path.present? && File.directory?(source_path)

    source = canonical_path(source_path)
    shared_roots = shared_download_roots(download).filter_map do |path|
      canonical_path(path) if path.present?
    end
    return unless shared_roots.include?(source)

    raise "Refusing to import shared download root: #{source_path}. " \
      "The download client must report a download-specific file or directory."
  end

  def shared_download_roots(download)
    roots = [
      SettingsService.get(:download_local_path, default: "/downloads"),
      SettingsService.get(:download_remote_path),
      download.download_client&.download_path
    ].compact_blank

    categories = category_path_variants(download.download_client&.category)
    return roots if categories.empty?

    roots + roots.flat_map { |root| categories.map { |category| File.join(root, category) } }
  end

  # Deluge normalizes labels to lowercase while other clients preserve the
  # configured category casing. Include both forms so path checks match disk.
  def category_path_variants(category)
    return [] if category.blank?

    value = category.to_s
    [ value, value.downcase, value.strip, value.strip.downcase ].map(&:presence).compact.uniq
  end

  def canonical_path(path)
    expanded = File.expand_path(normalize_path_separators(path))
    File.realpath(expanded)
  rescue SystemCallError
    expanded
  end

  def retry_source_path_later(download, request, source_path, retry_count)
    retry_limit = SettingsService.get(:post_processing_source_path_retries).to_i
    if retry_count < retry_limit
      next_retry_count = retry_count + 1
      wait_interval = SettingsService.get(:download_check_interval).to_i.clamp(1, 86_400).seconds

      Rails.logger.warn(
        "[PostProcessingJob] Source path not visible yet: #{source_path}. " \
          "Retrying post-processing source check #{next_retry_count}/#{retry_limit} in #{wait_interval.to_i}s."
      )

      track_request_event(
        request,
        "post_processing_waiting",
        download: download,
        message: "Source path not visible yet; retrying post-processing",
        level: :warn,
        details: { source_path: source_path, retry_count: next_retry_count, retry_limit: retry_limit }
      )

      retry_job = self.class.new(download.id, next_retry_count, job_id)
      raise "Failed to enqueue post-processing retry" unless retry_job.enqueue(wait: wait_interval)
      return
    end

    raise source_path_not_found_message(source_path)
  end

  def cleanup_usenet_download(download)
    return unless SettingsService.get(:remove_completed_usenet_downloads, default: true)
    return unless download.download_client&.usenet_client?
    return unless download.external_id.present?

    Rails.logger.info "[PostProcessingJob] Removing usenet download #{download.external_id} from #{download.download_client.name}"
    download.download_client.adapter.remove_torrent(download.external_id, delete_files: true)
    Rails.logger.info "[PostProcessingJob] Usenet download removed successfully"
  rescue => e
    Rails.logger.warn "[PostProcessingJob] Failed to remove usenet download (non-fatal): #{e.message}"
  end

  def build_destination_path(book, base_path: nil)
    base_path ||= get_base_path(book)
    PathTemplateService.build_destination(book, base_path: base_path)
  end

  # Flat imports write into the shared output root, so the root must not be
  # recorded as the book's own path when the import produced a single file.
  # Pointing file_path at that file keeps downloads and deletions per-book.
  def imported_book_path(book, destination)
    return @imported_book_path_override if @imported_book_path_override.present?
    return destination unless PathTemplateService.flat_output?(book)
    return destination unless @imported_renamed_files&.one?

    @imported_renamed_files.first
  end

  def get_base_path(book)
    # Always use Shelfarr's configured output paths.
    # External library paths are from that service's container perspective,
    # not ours, so they cannot drive file operations.
    if book.comicbook?
      SettingsService.get(:comicbook_output_path, default: "/comics")
    elsif book.ebook?
      SettingsService.get(:ebook_output_path, default: "/ebooks")
    else
      SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    end
  end

  def library_id_for(book)
    SettingsService.library_id_for_book(book)
  end

  def import_files(source, destination, book: nil, base_path: nil)
    unless source.present?
      Rails.logger.error "[PostProcessingJob] Source path is blank - download client may not have reported the path"
      raise "Source path is blank. Check download client configuration and ensure the download completed successfully."
    end

    unless File.exist?(source)
      Rails.logger.error "[PostProcessingJob] Source path does not exist: #{source}"
      Rails.logger.error "[PostProcessingJob] Check path remapping settings:"
      Rails.logger.error "[PostProcessingJob]   - download_remote_path: #{SettingsService.get(:download_remote_path).inspect}"
      Rails.logger.error "[PostProcessingJob]   - download_local_path: #{SettingsService.get(:download_local_path).inspect}"
      raise source_path_not_found_message(source)
    end

    directory_source = File.directory?(source)
    @imported_renamed_files = []
    @imported_book_path_override = nil
    @defer_source_removal = directory_source && move_completed_downloads?
    action = move_completed_downloads? ? "Moving" : "Copying"
    Rails.logger.info "[PostProcessingJob] #{action} from #{source} to #{destination}"
    validate_ebook_source!(source) if readable_file_import?(book)
    source_cleanup = nil

    if directory_source
      import_directory(source, destination, book: book, base_path: base_path)
      source_cleanup = -> { remove_import_source_tree(source) } if move_completed_downloads?
    else
      # Import single file with renamed filename based on template
      FileUtils.mkdir_p(destination)
      import_renamed_file(source, destination, book)
    end

    Rails.logger.info "[PostProcessingJob] #{action} completed successfully"
    source_cleanup
  ensure
    remove_instance_variable(:@defer_source_removal) if instance_variable_defined?(:@defer_source_removal)
  end

  def import_directory(source, destination, book:, base_path:)
    bundle_plan = audiobook_bundle_import_plan(source, book, base_path: base_path)
    if bundle_plan
      import_split_audiobook_bundle(bundle_plan)
      return
    end

    FileUtils.mkdir_p(destination)

    # Preserve dot-prefixed audiobook release files. Ebook/comic validation and
    # recursive import intentionally retain their existing hidden-file policy.
    files = if readable_file_import?(book)
      Dir.entries(source).reject { |file| file.start_with?(".") }
    else
      Dir.children(source)
    end
    Rails.logger.info "[PostProcessingJob] Found #{files.size} files/folders to import"
    files.each do |file|
      source_file = File.join(source, file)

      if readable_file_import?(book)
        import_ebook_directory_entry(source_file, destination, book)
      else
        import_directory_entry(source_file, destination)
      end
    end
  end

  def audiobook_bundle_import_plan(source, book, base_path:)
    return unless book&.audiobook?
    return unless SettingsService.get(:split_audiobook_bundle_imports, default: false)

    AudiobookBundleImportPlanner.call(
      source: source,
      book: book,
      base_path: base_path || get_base_path(book)
    )
  end

  def import_split_audiobook_bundle(plan)
    Rails.logger.info "[PostProcessingJob] Splitting audiobook bundle into #{plan.entries.size} per-book folders"

    plan.entries.each do |entry|
      FileUtils.mkdir_p(entry.destination)
      import_audiobook_bundle_file(entry.source_path, entry.destination)
      entry.sidecar_paths.each do |sidecar|
        import_sidecar_file(sidecar, entry.destination, retry_safe: true)
      end
    end

    tracked_destination = plan.tracked_entry.destination
    FileUtils.mkdir_p(tracked_destination)
    plan.unassigned_paths.each do |path|
      import_sidecar_file(path, tracked_destination, retry_safe: true)
    end
    @imported_book_path_override = tracked_destination
  end

  def import_audiobook_bundle_file(source_file, destination)
    destination_file = File.join(destination, File.basename(source_file))
    import_file_without_duplicate_content(source_file, destination_file)
  end

  def import_ebook_directory_entry(source_file, destination, book)
    if File.directory?(source_file) && !File.symlink?(source_file)
      Dir.entries(source_file).reject { |f| f.start_with?(".") }.each do |file|
        import_ebook_directory_entry(File.join(source_file, file), destination, book)
      end
    elsif allowed_ebook_import_file?(source_file) && ebook_file?(source_file)
      import_renamed_file(source_file, destination, book)
    elsif allowed_ebook_import_file?(source_file)
      import_sidecar_file(source_file, destination)
    else
      Rails.logger.info "[PostProcessingJob] Skipping unsupported ebook import file: #{File.basename(source_file)}"
    end
  end

  def readable_file_import?(book)
    book&.ebook? || book&.comicbook?
  end

  def validate_ebook_source!(source)
    unless File.directory?(source)
      return if ebook_file?(source) && allowed_ebook_import_file?(source)

      raise "Unsupported ebook import file type: #{File.basename(source)}"
    end

    supported_ebook_found = false
    paths = ebook_directory_files(source)

    paths.each do |path|
      if File.symlink?(path)
        raise "Unsupported ebook import file type: #{File.basename(path)}"
      end

      extension = File.extname(path).delete_prefix(".").downcase
      next unless EBOOK_ALLOWED_EXTENSIONS.include?(extension)

      unless allowed_ebook_import_file?(path)
        raise "Unsupported ebook import file type: #{File.basename(path)}"
      end

      supported_ebook_found ||= EBOOK_FILE_EXTENSIONS.include?(extension)
    end

    raise "No supported ebook files found in download" unless supported_ebook_found
  end

  def ebook_directory_files(source)
    Dir.entries(source).reject { |f| f.start_with?(".") }.flat_map do |file|
      path = File.join(source, file)
      File.directory?(path) && !File.symlink?(path) ? ebook_directory_files(path) : path
    end
  end

  def allowed_ebook_import_file?(path)
    return false if File.symlink?(path)
    return false unless File.file?(path)

    extension = File.extname(path).delete_prefix(".").downcase
    EBOOK_ALLOWED_EXTENSIONS.include?(extension) && valid_ebook_import_content?(path, extension)
  end

  def valid_ebook_import_content?(path, extension)
    file_size = File.size(path)
    return false if file_size.zero?

    head = File.binread(path, [ 512, file_size ].min)
    return false if executable_file_signature?(head)

    case extension
    when "epub", "cbz"
      head.start_with?("PK\x03\x04")
    when "pdf"
      head.start_with?("%PDF")
    when "mobi", "azw", "azw3"
      head.byteslice(60, 8) == "BOOKMOBI" || head.include?("BOOKMOBI")
    when "cbr"
      head.start_with?("Rar!\x1A\x07\x00") || head.start_with?("Rar!\x1A\x07\x01\x00")
    when "djvu"
      head.start_with?("AT&TFORM") && %w[DJVU DJVM].include?(head.byteslice(12, 4))
    when "jpg", "jpeg"
      head.start_with?("\xFF\xD8\xFF".b)
    when "png"
      head.start_with?("\x89PNG\r\n\x1A\n".b)
    when "webp"
      head.start_with?("RIFF") && head.byteslice(8, 4) == "WEBP"
    when "opf"
      text_file_content?(head) && head.downcase.include?("<package")
    when "nfo", "txt"
      text_file_content?(head)
    else
      false
    end
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def executable_file_signature?(head)
    head.start_with?("MZ") ||
      head.start_with?("\x7FELF".b) ||
      head.start_with?("\xFE\xED\xFA\xCE".b) ||
      head.start_with?("\xFE\xED\xFA\xCF".b) ||
      head.start_with?("\xCE\xFA\xED\xFE".b) ||
      head.start_with?("\xCF\xFA\xED\xFE".b)
  end

  def text_file_content?(head)
    return false if head.include?("\x00")

    head.bytes.all? do |byte|
      byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte >= 32
    end
  end

  def import_sidecar_file(source_file, destination, retry_safe: false)
    destination_file = File.join(destination, File.basename(source_file))
    if retry_safe
      import_file_without_duplicate_content(source_file, destination_file)
    else
      destination_file = handle_duplicate_filename(destination_file) if path_occupied?(destination_file)
      import_file(source_file, destination_file)
    end
  end

  def import_renamed_file(source, destination, book)
    destination_file = renamed_destination_file(source, destination, book)
    Rails.logger.info "[PostProcessingJob] Renaming file to: #{File.basename(destination_file)}"
    import_file(source, destination_file)
    @imported_renamed_files << destination_file
  end

  def import_file(source, destination)
    if move_completed_downloads? && !@defer_source_removal
      FileCopyService.mv(source, destination)
    else
      FileCopyService.cp(source, destination)
    end
  end

  def import_file_without_duplicate_content(source, destination)
    original_destination = destination
    cleanup_interrupted_imports(File.dirname(original_destination))
    destination, already_imported = retry_safe_destination(source, original_destination)
    if already_imported
      Rails.logger.info "[PostProcessingJob] Skipping already imported file: #{destination}"
      return destination
    end

    atomic_import_file(source, original_destination, destination)
  end

  def retry_safe_destination(source, destination)
    candidate = destination
    counter = 1

    loop do
      break unless path_occupied?(candidate)

      if !File.symlink?(candidate) && same_file_content?(source, candidate)
        return [ candidate, true ]
      end

      counter += 1
      candidate = duplicate_filename_candidate(destination, counter)
    end

    [ candidate, false ]
  end

  def atomic_import_file(source, original_destination, destination)
    directory = File.dirname(destination)
    token = SecureRandom.hex(16)
    temporary_destination = File.join(directory, ".shelfarr-import-#{token}.tmp")
    lock_path = File.join(directory, ".shelfarr-import-#{token}.lock")
    lock_identity = nil
    lock_flags = File::RDWR | File::CREAT | File::EXCL | File::BINARY

    File.open(lock_path, lock_flags, 0o600) do |lock|
      lock_identity = file_identity(lock.stat)
      lock.flock(File::LOCK_EX)
      lock.write("#{IMPORT_TEMP_LOCK_MAGIC}:#{token}")
      flush_and_sync(lock)
      sync_directory(directory)

      begin
        import_file(source, temporary_destination)
        sync_regular_file(temporary_destination)
        publish_imported_file(temporary_destination, original_destination, destination)
      ensure
        remove_regular_file(temporary_destination)
        sync_directory(directory)
      end
    end
  ensure
    remove_path_if_identity(lock_path, lock_identity) if lock_path
    sync_directory(directory) if directory
  end

  def publish_imported_file(temporary_source, original_destination, destination)
    hard_links_supported = true

    loop do
      if hard_links_supported
        link_result = try_hard_link(temporary_source, destination)
        return destination if link_result == :published

        hard_links_supported = false if link_result == :unsupported
      end

      unless hard_links_supported
        rename_result = try_no_replace_rename(temporary_source, destination)
        return destination if rename_result == :published

        if rename_result == :unsupported
          raise AtomicPublicationUnsupportedError,
            "The destination filesystem cannot atomically publish split audiobook files"
        end
      end

      destination, already_imported = retry_safe_destination(temporary_source, original_destination)
      return destination if already_imported
    end
  end

  def try_hard_link(source, destination)
    File.link(source, destination)
    :published
  rescue Errno::EEXIST
    :occupied
  rescue Errno::EPERM, Errno::EOPNOTSUPP, Errno::ENOSYS, NotImplementedError
    :unsupported
  end

  def try_no_replace_rename(source, destination)
    function, platform = no_replace_rename_function
    return :unsupported unless function

    Fiddle.last_error = 0
    result = if platform == :darwin
      function.call(source, destination, DARWIN_RENAME_EXCL)
    else
      function.call(AT_FDCWD, source, AT_FDCWD, destination, LINUX_RENAME_NOREPLACE)
    end
    return :published if result.zero?

    error_number = Fiddle.last_error
    return :occupied if error_number == Errno::EEXIST::Errno
    return :unsupported if atomic_rename_unsupported_error?(error_number)

    raise SystemCallError.new("Atomic file publication failed", error_number)
  end

  def no_replace_rename_function
    return @no_replace_rename_function if defined?(@no_replace_rename_function)

    @no_replace_rename_function = if RUBY_PLATFORM.include?("darwin")
      address = Fiddle::Handle::DEFAULT["renamex_np"]
      function = Fiddle::Function.new(
        address,
        [ Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT ],
        Fiddle::TYPE_INT
      )
      [ function, :darwin ]
    elsif RUBY_PLATFORM.include?("linux")
      address = Fiddle::Handle::DEFAULT["renameat2"]
      function = Fiddle::Function.new(
        address,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT ],
        Fiddle::TYPE_INT
      )
      [ function, :linux ]
    else
      [ nil, nil ]
    end
  rescue Fiddle::DLError
    @no_replace_rename_function = [ nil, nil ]
  end

  def atomic_rename_unsupported_error?(error_number)
    [ Errno::ENOSYS::Errno, Errno::EINVAL::Errno, Errno::EOPNOTSUPP::Errno ].include?(error_number)
  end

  def cleanup_interrupted_imports(directory)
    Dir.children(directory).each do |entry|
      match = IMPORT_TEMP_LOCK_PATTERN.match(entry)
      next unless match

      token = match[1]
      lock_path = File.join(directory, entry)
      lock_stat = File.lstat(lock_path)
      next unless lock_stat.file? && !lock_stat.symlink?

      File.open(lock_path, "r+b") do |lock|
        next unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        next unless path_matches_identity?(lock_path, file_identity(lock.stat))

        lock.rewind
        next unless lock.read == "#{IMPORT_TEMP_LOCK_MAGIC}:#{token}"

        remove_regular_file(File.join(directory, ".shelfarr-import-#{token}.tmp"))
        remove_path_if_identity(lock_path, file_identity(lock.stat))
        sync_directory(directory)
      end
    rescue Errno::ENOENT, Errno::EACCES, IOError
      next
    end
  end

  def remove_regular_file(path)
    stat = File.lstat(path)
    FileUtils.rm_f(path) if stat.file? && !stat.symlink?
  rescue Errno::ENOENT
    nil
  end

  def remove_path_if_identity(path, identity)
    FileUtils.rm_f(path) if path_matches_identity?(path, identity)
  rescue Errno::ENOENT
    nil
  end

  def flush_and_sync(file)
    file.flush
    file.fsync
  rescue Errno::EINVAL, Errno::EOPNOTSUPP
    nil
  end

  def sync_directory(path)
    File.open(path, File::RDONLY) { |directory| directory.fsync }
  rescue SystemCallError, IOError
    nil
  end

  def sync_regular_file(path)
    File.open(path, "rb", &:fsync)
  rescue Errno::EINVAL, Errno::EOPNOTSUPP
    nil
  end

  def file_identity(stat)
    [ stat.dev, stat.ino ]
  end

  def path_matches_identity?(path, identity)
    return false unless identity

    stat = File.lstat(path)
    stat.file? && !stat.symlink? && file_identity(stat) == identity
  rescue Errno::ENOENT
    false
  end

  def same_file_content?(source, destination)
    return false unless File.file?(source) && File.file?(destination)

    File.identical?(source, destination) || FileUtils.compare_file(source, destination)
  rescue SystemCallError, IOError
    false
  end

  def import_directory_entry(source, destination)
    FileCopyService.cp_r(source, destination)
  end

  def move_completed_downloads?
    return @move_completed_downloads if defined?(@move_completed_downloads)

    @move_completed_downloads = SettingsService.get(:move_completed_downloads, default: false)
  end

  def remove_import_source(source_cleanup)
    source_cleanup&.call
  rescue => e
    Rails.logger.warn "[PostProcessingJob] Failed to remove import source (non-fatal): #{e.message}"
  end

  def remove_import_source_tree(path)
    FileUtils.rm_rf(path)
  rescue Errno::ENOENT
    nil
  end

  def renamed_destination_file(source, destination, book)
    extension = File.extname(source)
    new_filename = book ? PathTemplateService.build_filename(book, extension) : File.basename(source)
    destination_file = File.join(destination, new_filename)

    destination_file = handle_duplicate_filename(destination_file) if path_occupied?(destination_file)
    destination_file
  end

  def ebook_file?(path)
    EBOOK_FILE_EXTENSIONS.include?(File.extname(path).delete_prefix(".").downcase)
  end

  def handle_duplicate_filename(path)
    counter = 1
    new_path = path
    while path_occupied?(new_path)
      counter += 1
      new_path = duplicate_filename_candidate(path, counter)
    end
    new_path
  end

  def duplicate_filename_candidate(path, counter)
    dir = File.dirname(path)
    ext = File.extname(path)
    base = File.basename(path, ext)
    suffix = " (#{counter})"
    available_base_bytes = MAX_FILENAME_BYTES - suffix.bytesize - ext.bytesize
    raise Errno::ENAMETOOLONG, path if available_base_bytes.negative?

    base = truncate_to_bytes(base, available_base_bytes)
    File.join(dir, "#{base}#{suffix}#{ext}")
  end

  def truncate_to_bytes(value, maximum_bytes)
    return value if value.bytesize <= maximum_bytes

    truncated = value.byteslice(0, maximum_bytes).to_s
    truncated.valid_encoding? ? truncated : truncated.scrub("")
  end

  def path_occupied?(path)
    File.exist?(path) || File.symlink?(path)
  end

  # Remap paths from download client (host) to container paths.
  # Builds a list of candidate paths and returns the first one that exists on disk.
  # This handles different client configurations (with/without category, with/without
  # per-client download_path) without requiring a single "correct" configuration.
  def remap_download_path(path, download)
    if path.blank?
      Rails.logger.warn "[PostProcessingJob] Download path is blank - download client didn't report a path"
      return path
    end

    Rails.logger.info "[PostProcessingJob] Path remapping - original path from client: #{path}"

    candidates = build_path_candidates(path, download)
    candidates = deduplicate_path_candidates(candidates)

    # Return the first candidate that actually exists on disk.
    candidates.each do |candidate|
      next if candidate[:path].blank?

      if File.exist?(candidate[:path])
        Rails.logger.info "[PostProcessingJob] Path resolved via #{candidate[:strategy]}: #{candidate[:path]}"
        return candidate[:path]
      end
    end

    # None found - log all candidates for debugging
    Rails.logger.warn "[PostProcessingJob] No remapped path exists on disk. Candidates tried:"
    candidates.each { |c| Rails.logger.warn "[PostProcessingJob]   #{c[:strategy]}: #{c[:path]}" }

    # Return the first non-nil candidate so import_files produces a clear "not found" error
    best_guess = candidates.find { |c| c[:path].present? }
    best_guess ? best_guess[:path] : path
  end

  def build_path_candidates(path, download)
    candidates = []
    normalized_path = normalize_path_separators(path)
    remote_path = normalize_path_separators(SettingsService.get(:download_remote_path))
    local_path = normalize_path_separators(SettingsService.get(:download_local_path, default: "/downloads"))
    categories = category_path_variants(download.download_client&.category)
    client_download_path = normalize_path_separators(download.download_client&.download_path)
    basename = File.basename(normalized_path)

    # 1. Global remote_path → local_path prefix replacement
    if remote_path.present? && path_prefix_match?(normalized_path, remote_path)
      candidates << { strategy: "global_prefix_remap", path: replace_path_prefix(normalized_path, remote_path, local_path) }
    end

    # 2. local_path/category/basename — most common torrent client layout
    categories.each do |category|
      candidates << { strategy: "local_path_with_category", path: File.join(local_path, category, basename) }
    end

    # 3. Category-aware sibling remap — when remote_path points to a sibling folder
    #    e.g., remote=/mnt/Torrents/Completed, path=/mnt/Torrents/shelfarr/File
    if remote_path.present?
      categories.each do |category|
        marker = "/#{category}/"
        next unless normalized_path.include?(marker)

        category_idx = normalized_path.index(marker)
        remote_base = normalized_path[0...category_idx]
        relative_after_base = normalized_path[(category_idx)..]

        if remote_base == File.dirname(remote_path)
          candidates << { strategy: "category_sibling_remap", path: File.join(File.dirname(local_path), relative_after_base) }
        end
      end
    end

    # 4. Client download_path + basename
    if client_download_path.present?
      candidates << { strategy: "client_download_path", path: File.join(client_download_path, basename) }
    end

    # 5. local_path/basename (no category)
    candidates << { strategy: "local_path_basename", path: File.join(local_path, basename) }

    # 6. Original path as-is (works when download client runs in the same filesystem)
    candidates << { strategy: "original_path", path: path }

    candidates
  end

  def normalize_path_separators(path)
    path.to_s.tr("\\", "/") if path.present?
  end

  def path_prefix_match?(path, prefix)
    return false unless path.start_with?(prefix)

    path.length == prefix.length || prefix.end_with?("/") || path[prefix.length] == "/"
  end

  def replace_path_prefix(path, remote_path, local_path)
    suffix = path.delete_prefix(remote_path).sub(%r{\A/+}, "")
    suffix.present? ? File.join(local_path, suffix) : local_path
  end

  def deduplicate_path_candidates(candidates)
    seen = {}

    candidates.select do |candidate|
      path = candidate[:path]
      next true if path.blank?
      next false if seen.key?(path)

      seen[path] = true
      true
    end
  end

  def source_path_not_found_message(source)
    "Source path not found: #{source}. Verify path remapping settings " \
      "(download_remote_path/download_local_path) match your container mount points."
  end

  def track_request_event(request, event_type, download: nil, message: nil, level: :info, details: {})
    RequestEvent.record!(
      request: request,
      download: download,
      event_type: event_type,
      source: self.class.name,
      message: message,
      level: level,
      details: details
    )
  end

  def sanitize_filename(name)
    # Remove invalid filename characters, collapse whitespace
    name
      .gsub(/[<>:"\/\\|?*]/, "")  # Remove invalid chars
      .gsub(/[\x00-\x1f]/, "")    # Remove control characters
      .strip
      .gsub(/\s+/, " ")           # Collapse whitespace
      .truncate(100, omission: "") # Limit length
  end

  def pre_create_download_zip(book, path)
    require "zip"

    zip_filename = "#{book.author} - #{book.title}.zip".gsub(/[\/\\:*?"<>|]/, "_")
    safe_filename = zip_filename.gsub(/\s+/, "_")

    downloads_dir = Rails.root.join("tmp", "downloads")
    FileUtils.mkdir_p(downloads_dir)
    zip_path = downloads_dir.join("book_#{book.id}_#{safe_filename}")

    Rails.logger.info "[PostProcessingJob] Pre-creating download zip: #{zip_path}"

    Zip::File.open(zip_path.to_s, create: true) do |zipfile|
      Dir.entries(path).reject { |f| f.start_with?(".") }.each do |file|
        full_path = File.join(path, file)
        next if File.directory?(full_path)
        zipfile.add(file, full_path)
      end
    end

    Rails.logger.info "[PostProcessingJob] Download zip ready: #{(File.size(zip_path) / 1024.0 / 1024.0).round(2)} MB"
  rescue => e
    Rails.logger.warn "[PostProcessingJob] Failed to pre-create zip (non-fatal): #{e.message}"
    # Non-fatal - zip will be created on first download
  end

  def trigger_library_scan(book)
    lib_id = library_id_for(book)
    return unless lib_id.present?

    LibraryPlatformClient.scan_library(lib_id)
    Rails.logger.info "[PostProcessingJob] Triggered #{LibraryPlatformClient.display_name} library scan for #{book.book_type}"
  rescue LibraryPlatformClient::Error => e
    Rails.logger.warn "[PostProcessingJob] Failed to trigger scan: #{e.message}"
    # Non-fatal - the library platform will pick up files on next auto-scan.
  end
end
