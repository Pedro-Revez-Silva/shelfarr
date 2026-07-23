# frozen_string_literal: true

require "set"
require "logger"

# Imports completed downloads to the library folder and triggers library scan.
# Files are copied by default to preserve seeding for torrent downloads.
# Usenet downloads are removed from the client after successful import.
class PostProcessingJob < ApplicationJob
  EBOOK_FILE_EXTENSIONS = %w[epub pdf mobi azw azw3 cbz cbr djvu].freeze
  EBOOK_SIDECAR_EXTENSIONS = %w[jpg jpeg png webp opf nfo txt].freeze
  EBOOK_ALLOWED_EXTENSIONS = (EBOOK_FILE_EXTENSIONS + EBOOK_SIDECAR_EXTENSIONS).freeze
  MAX_FILENAME_BYTES = 255
  POST_PROCESSING_LOCK_SLOTS = 256
  class BookAcquisitionConflictError < StandardError; end
  class DestructiveImportOverlapError < StandardError; end

  queue_as :default

  def perform(download_id, source_path_retry_count = 0, expected_owner_job_id = nil)
    if Rails.logger.respond_to?(:silence)
      # Active Record DEBUG binds can contain Book titles and library paths.
      # Post-processing logs only opaque record IDs and error classes, so keep
      # the entire acquisition below INFO even in verbose development mode.
      Rails.logger.silence(Logger::INFO) do
        perform_privately(download_id, source_path_retry_count, expected_owner_job_id)
      end
    else
      perform_privately(download_id, source_path_retry_count, expected_owner_job_id)
    end
  end

  private

  def perform_privately(download_id, source_path_retry_count, expected_owner_job_id)
    @hardlinked_file_count = 0
    @hardlink_fallback_copied_count = 0
    @reused_file_count = 0
    download = Download.find_by(id: download_id)
    return unless download&.completed?

    with_post_processing_lock(download.id) do
      perform_locked(download, source_path_retry_count, expected_owner_job_id)
    end
  end

  def perform_locked(download, source_path_retry_count, expected_owner_job_id)
    download.reload
    return unless download.completed?

    request = download.request
    return unless claim_request_for_post_processing(download, request, expected_owner_job_id)

    book = request.book
    acquisition_finalized = false

    Rails.logger.info "[PostProcessingJob] Starting download ##{download.id}, book ##{book.id}"

    begin
      book.reload
      if book.acquisition_reserved?
        raise BookAcquisitionConflictError,
          "This title already has an acquisition in progress; its recovery reservation was preserved"
      end

      # Shelfarr versions which predate atomic finalization could be killed
      # after attaching the imported path to Book but before completing the
      # Request. The durable Download owner proves this request still needs
      # reconciliation, so finish only the database transition and retain the
      # download source for manual cleanup.
      if book.acquired?
        unless verifiable_library_entry?(book.file_path)
          raise BookAcquisitionConflictError,
            "The existing library entry could not be verified; its database state was preserved for review"
        end

        acquisition_finalized = finalize_acquisition!(
          download,
          request,
          book,
          book.file_path
        )
        return unless acquisition_finalized

        run_completion_side_effects(request, download, book, book.file_path)
        return
      end

      base_path = get_base_path(book)
      destination = build_destination_path(book, base_path: base_path)
      source_resolution = remap_download_path(download.download_path, download)
      source_path = source_resolution[:path]
      if source_path_unavailable?(source_path)
        return retry_source_path_later(download, request, source_path, source_path_retry_count)
      end
      source_authorization = validate_download_specific_source_path!(
        source_path,
        source_resolution[:authorized_roots],
        download
      )

      remove_usenet_download = usenet_cleanup_requested?(download)
      source_cleanup = import_files(
        source_path,
        destination,
        book: book,
        base_path: base_path,
        require_durable: move_completed_downloads? || remove_usenet_download,
        source_authorization: source_authorization
      )

      book_path = imported_book_path(book, destination)
      cleanup_state = source_cleanup&.fetch(:state)
      acquisition_finalized = finalize_acquisition!(download, request, book, book_path, cleanup_state)
      return unless acquisition_finalized

      # Destructive source/client cleanup happens only after Book, Request, and
      # Download ownership commit together. A hard kill before that commit can
      # therefore retry the idempotent import without losing its source.
      cleanup_outcome = remove_import_source(source_cleanup)
      if cleanup_state && cleanup_outcome != :retry
        clear_source_cleanup_state(download, cleanup_state)
      end
      cleanup_usenet_download(download) if remove_usenet_download && cleanup_outcome == :complete

      run_completion_side_effects(request, download, book, book_path)
    rescue => e
      Rails.logger.error "[PostProcessingJob] Download ##{download.id} failed: #{e.class}"
      mark_post_processing_failure!(download, request, e) unless acquisition_finalized
    end
  end

  def with_post_processing_lock(download_id, &operation)
    tmp_root = Rails.root.join("tmp")
    lock_root = tmp_root.join("post-processing-locks")
    FileCopyService.ensure_directory(lock_root.to_s, root: tmp_root.to_s, mode: 0o700)
    FileCopyService.secure_private_directory!(lock_root.to_s, root: tmp_root.to_s)
    lock_slot = download_id % POST_PROCESSING_LOCK_SLOTS
    lock_path = lock_root.join("#{lock_slot}.lock")
    FileCopyService.with_private_lock(lock_path.to_s, root: lock_root.to_s, &operation)
  end

  def claim_request_for_post_processing(download, request, expected_owner_job_id)
    request.with_acquisition_transition_lock do
      download.reload
      return false unless download.completed?
      return false if request.completed?
      return false unless request.downloading? || request.processing?
      return false if request.upload_cancellation_blocked?
      return false if request.direct_acquisition_recovery_pending?

      selected_result_id = request.search_results.selected.pick(:id)
      return false if download.search_result_id.present? && download.search_result_id != selected_result_id
      return false if request.downloads.active.where.not(id: download.id).exists?
      return false unless download.claim_post_processing!(job_id, expected_owner_job_id: expected_owner_job_id)

      request.update!(status: :processing) unless request.processing?
    end

    true
  rescue ActiveRecord::RecordNotFound
    false
  end

  def finalize_acquisition!(download, request, book, imported_path, cleanup_state = nil)
    finalized = request.with_acquisition_transition_lock do
      download.reload
      book.reload

      next false unless download.completed?
      next false unless download.post_processing_job_id == job_id
      next false unless request.processing?

      if book.acquisition_reserved?
        raise BookAcquisitionConflictError,
          "Another acquisition owns this title's recovery reservation"
      end

      if book.file_path.blank?
        claimed = Book.where(id: book.id)
          .where("file_path IS NULL OR TRIM(file_path) = ''")
          .where(acquisition_reservation_token: nil)
          .update_all(file_path: imported_path, updated_at: Time.current)
        unless claimed == 1
          raise BookAcquisitionConflictError,
            "Another acquisition claimed this title while post-processing was finalizing"
        end
        book.file_path = imported_path
      elsif book.file_path != imported_path
        raise BookAcquisitionConflictError,
          "Another acquisition already attached a different library file to this title"
      end

      # Clearing the owner and completing the Request in one transaction closes
      # both crash windows: recovery never sees a completed Request with an
      # outstanding owner, nor a processing Request whose Book path was already
      # committed by this job.
      download.update!(
        post_processing_job_id: nil,
        post_processing_cleanup_state: cleanup_state
      )
      request.complete!
      true
    end

    finalized == true
  rescue ActiveRecord::RecordNotFound
    false
  end

  def mark_post_processing_failure!(download, request, error)
    marked = request.with_acquisition_transition_lock do
      download.reload
      next false unless request.processing?
      next false unless download.completed?
      next false unless download.post_processing_job_id == job_id

      request.mark_for_attention!(safe_attention_message(error))
      true
    end
    marked == true
  rescue ActiveRecord::RecordNotFound
    false
  end

  def run_completion_side_effects(request, download, book, book_path)
    # Pre-create zip for directories (audiobooks) so download is instant.
    # Flat imports share the output root, which must never be zipped whole.
    if File.directory?(book_path) && (!PathTemplateService.flat_output?(book) || @imported_book_path_override.present?)
      begin
        LibraryDownloadArchiveService.call(
          book: book,
          source_path: book_path,
          output_root: get_base_path(book)
        )
      rescue LibraryDownloadArchiveService::Error, SystemCallError => error
        Rails.logger.warn(
          "[PostProcessingJob] Download archive pre-creation failed for book ##{book.id}: #{error.class}"
        )
      end
    end

    trigger_library_scan(book) if LibraryPlatformClient.configured?
    NotificationService.request_completed(request)

    Rails.logger.info "[PostProcessingJob] Completed processing for download #{download.id}"
  rescue => error
    # These are post-commit conveniences. Their failure must never reopen or
    # overwrite the completed acquisition state.
    Rails.logger.warn(
      "[PostProcessingJob] Completion side effect failed for download #{download.id}: #{error.class}"
    )
  end

  def safe_attention_message(error)
    detail = case error
    when BookAcquisitionConflictError
      error.message
    when FileCopyService::UnsafeFilePermissionsError
      "The library filesystem cannot enforce safe file permissions; it must support mode 0600 or 0640"
    when FileCopyService::DurabilityUnsupportedError
      "The library filesystem cannot safely complete destructive imports because fsync is unsupported; use another filesystem or retain the download source"
    when FileCopyService::UnsafePathError
      "The download contains a symbolic link or non-regular path, or changed during its safety checks"
    when AudiobookBundleImportPlanner::UnsafeDestinationError
      "The configured audiobook bundle destination overlaps the download source"
    when DestructiveImportOverlapError
      "The configured library destination overlaps the download source"
    when Errno::ENOSPC
      "The library filesystem ran out of space"
    when Errno::EACCES, Errno::EPERM
      "Shelfarr does not have permission to read the download or write the library"
    else
      safe_attention_detail(error)
    end

    "Post-processing failed: #{detail.to_s.first(500)}"
  end

  def safe_attention_detail(error)
    case error.message.to_s
    when /source path is blank/i
      "Source path is blank because the download client did not report one"
    when /source path not found/i
      "Source path not found at Shelfarr's configured download mount"
    when /shared download root/i
      "Refusing to import shared download root; a download-specific path is required"
    when /outside (?:a )?configured download root/i
      "Refusing to import source outside configured download roots"
    when /no supported ebook files/i
      "No supported ebook files found in the completed download"
    when /unsupported ebook import file type/i
      "Unsupported ebook import file type or invalid ebook content"
    when /failed to enqueue post-processing retry/i
      "Shelfarr could not enqueue the next source-path check"
    else
      "A safe filesystem operation failed (#{error.class})"
    end
  end

  def verifiable_library_entry?(path)
    stat = File.lstat(path)
    stat.file? || stat.directory?
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
    false
  end

  def source_path_unavailable?(source_path)
    source_path.present? && !File.exist?(source_path)
  end

  def validate_download_specific_source_path!(source_path, authorized_roots, download)
    return unless source_path.present?

    source = canonical_path(source_path)
    roots = Array(authorized_roots).filter_map { |path| canonical_download_root(path) }.uniq
    shared_roots = shared_download_roots(download).filter_map { |path| canonical_download_root(path) }.uniq

    if shared_roots.include?(source)
      raise "Refusing to import shared download root. " \
        "The download client must report a download-specific file or directory."
    end

    unless roots.any? { |root| path_inside_root?(source, root) }
      raise "Refusing to import source outside a configured download root."
    end

    source_stat = File.lstat(source_path)
    snapshot = if source_stat.directory?
      FileCopyService.snapshot_source_root(source_path)
    elsif source_stat.file?
      FileCopyService.snapshot_source_file(source_path)
    else
      raise "Refusing to import non-regular path"
    end
    snapshotted_path = if source_stat.directory?
      snapshot.canonical_path.to_s
    else
      snapshot.canonical_parent_path.join(snapshot.path.basename).to_s
    end
    if shared_roots.include?(snapshotted_path)
      raise "Refusing to import shared download root. " \
        "The download client must report a download-specific file or directory."
    end
    unless roots.any? { |root| path_inside_root?(snapshotted_path, root) }
      raise "Refusing to import source outside a configured download root."
    end

    { directory: source_stat.directory?, snapshot: snapshot }
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
  end

  def canonical_download_root(path)
    expanded = File.expand_path(normalize_path_separators(path))
    return unless File.directory?(expanded)

    canonical = File.realpath(expanded)
    return if Pathname(canonical).root?

    canonical
  rescue ArgumentError, SystemCallError
    nil
  end

  def path_inside_root?(path, root)
    path.start_with?("#{root}#{File::SEPARATOR}")
  end

  def retry_source_path_later(download, request, source_path, retry_count)
    retry_limit = SettingsService.get(:post_processing_source_path_retries).to_i
    if retry_count < retry_limit
      next_retry_count = retry_count + 1
      wait_interval = SettingsService.get(:download_check_interval).to_i.clamp(1, 86_400).seconds

      Rails.logger.warn(
        "[PostProcessingJob] Source path is not visible for download ##{download.id}. " \
          "Retrying post-processing source check #{next_retry_count}/#{retry_limit} in #{wait_interval.to_i}s."
      )

      track_request_event(
        request,
        "post_processing_waiting",
        download: download,
        message: "Source path not visible yet; retrying post-processing",
        level: :warn,
        details: { retry_count: next_retry_count, retry_limit: retry_limit }
      )

      retry_job = self.class.new(download.id, next_retry_count, job_id)
      raise "Failed to enqueue post-processing retry" unless retry_job.enqueue(wait: wait_interval)
      return
    end

    raise source_path_not_found_message(source_path)
  end

  def cleanup_usenet_download(download)
    Rails.logger.info "[PostProcessingJob] Removing usenet download ##{download.id}"
    download.download_client.adapter.remove_torrent(download.external_id, delete_files: true)
    Rails.logger.info "[PostProcessingJob] Usenet download removed successfully"
  rescue => e
    Rails.logger.warn "[PostProcessingJob] Usenet cleanup failed for download ##{download.id}: #{e.class}"
  end

  def usenet_cleanup_requested?(download)
    SettingsService.get(:remove_completed_usenet_downloads, default: true) &&
      download.download_client&.usenet_client? &&
      download.external_id.present?
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

  def import_files(
    source,
    destination,
    book: nil,
    base_path: nil,
    require_durable: false,
    source_authorization: nil
  )
    unless source.present?
      Rails.logger.error "[PostProcessingJob] Source path is blank - download client may not have reported the path"
      raise "Source path is blank. Check download client configuration and ensure the download completed successfully."
    end

    unless File.exist?(source)
      Rails.logger.error "[PostProcessingJob] Completed download source is not visible"
      raise source_path_not_found_message(source)
    end

    source_authorization ||= authorize_import_source(source)
    directory_source = source_authorization.fetch(:directory)
    source_snapshot = source_authorization.fetch(:snapshot)
    @import_source_root = source_snapshot if directory_source
    @import_source_file_snapshot = source_snapshot unless directory_source
    @imported_renamed_files = []
    @imported_source_files = Set.new
    @verified_library_snapshots = Hash.new { |snapshots, path| snapshots[path] = [] }
    @imported_book_path_override = nil
    @import_base_path = Pathname(base_path || get_base_path(book)).expand_path
    @defer_source_removal = move_completed_downloads?
    @require_durable_import = require_durable
    validate_destructive_import_paths!(source_snapshot, destination) if require_durable
    action = {
      "copy" => "Copying",
      "move" => "Moving",
      "hardlink" => "Hardlinking"
    }.fetch(completed_download_import_mode, "Copying")
    Rails.logger.info "[PostProcessingJob] #{action} library content"
    validate_ebook_source!(source) if readable_file_import?(book)
    source_cleanup = nil

    if directory_source
      import_directory(source, destination, book: book, base_path: base_path)
      source_root = @import_source_root
      imported_source_files = @imported_source_files.dup.freeze
      destination_snapshots = @verified_library_snapshots.values.flatten.freeze
      if move_completed_downloads?
        source_cleanup = {
          operation: lambda do
            remove_import_source_tree(source_root, imported_source_files, destination_snapshots)
          end,
          state: nil,
          source_snapshot: nil
        }
      elsif require_durable
        source_cleanup = {
          operation: -> { destination_snapshots_current?(destination_snapshots) },
          state: nil,
          source_snapshot: nil
        }
      end
    else
      # Import single file with renamed filename based on template
      ensure_real_import_directory!(destination)
      import_renamed_file(source, destination, book)
      source_snapshot = @import_source_file_snapshot
      if source_snapshot && move_completed_downloads?
        destination_snapshot = @verified_library_snapshots.fetch(Pathname(source).expand_path.to_s).sole
        cleanup_state = JSON.generate(
          "source" => FileCopyService.serialize_file_snapshot(source_snapshot),
          "destination" => FileCopyService.serialize_file_snapshot(destination_snapshot)
        )
        source_cleanup = {
          operation: -> { remove_import_source_file(source_snapshot, destination_snapshot) },
          state: cleanup_state,
          source_snapshot: source_snapshot
        }
      elsif require_durable
        destination_snapshot = @verified_library_snapshots.fetch(Pathname(source).expand_path.to_s).sole
        source_cleanup = {
          operation: -> { destination_snapshots_current?([ destination_snapshot ]) },
          state: nil,
          source_snapshot: nil
        }
      end
    end

    if hardlink_completed_downloads?
      Rails.logger.info(
        "[PostProcessingJob] Hardlink import completed successfully: " \
          "#{@hardlinked_file_count} hardlinked, " \
          "#{@hardlink_fallback_copied_count} copied after unsupported fallback, " \
          "#{@reused_file_count} reused"
      )
    else
      Rails.logger.info "[PostProcessingJob] #{action} completed successfully"
    end
    source_cleanup
  ensure
    remove_instance_variable(:@defer_source_removal) if instance_variable_defined?(:@defer_source_removal)
    remove_instance_variable(:@import_base_path) if instance_variable_defined?(:@import_base_path)
    remove_instance_variable(:@import_source_root) if instance_variable_defined?(:@import_source_root)
    remove_instance_variable(:@import_source_file_snapshot) if instance_variable_defined?(:@import_source_file_snapshot)
    remove_instance_variable(:@verified_library_snapshots) if instance_variable_defined?(:@verified_library_snapshots)
    remove_instance_variable(:@require_durable_import) if instance_variable_defined?(:@require_durable_import)
  end

  def authorize_import_source(source)
    stat = File.lstat(source)
    if stat.directory?
      { directory: true, snapshot: FileCopyService.snapshot_source_root(source) }
    elsif stat.file?
      { directory: false, snapshot: FileCopyService.snapshot_source_file(source) }
    else
      raise "Refusing to import non-regular path: #{source}"
    end
  end

  def validate_destructive_import_paths!(source_snapshot, destination)
    source_path = if source_snapshot.is_a?(FileCopyService::SourceRoot)
      source_snapshot.canonical_path
    else
      source_snapshot.canonical_parent_path.join(source_snapshot.path.basename)
    end
    expanded_destination = Pathname(destination).expand_path
    relative_destination = expanded_destination.relative_path_from(@import_base_path)
    canonical_destination = @import_base_path.realpath.join(relative_destination)

    if paths_overlap?(source_path, canonical_destination)
      raise DestructiveImportOverlapError,
        "destructive import destination overlaps the download source"
    end
  rescue ArgumentError
    raise FileCopyService::UnsafePathError,
      "destructive import destination is outside the configured library root"
  end

  def paths_overlap?(left, right)
    left = Pathname(left).expand_path.to_s
    right = Pathname(right).expand_path.to_s
    left == right || left.start_with?("#{right}#{File::SEPARATOR}") ||
      right.start_with?("#{left}#{File::SEPARATOR}")
  end

  def import_directory(source, destination, book:, base_path:)
    bundle_plan = audiobook_bundle_import_plan(source, book, base_path: base_path)
    if bundle_plan
      import_split_audiobook_bundle(bundle_plan)
      return
    end

    ensure_real_import_directory!(destination)

    # Preserve dot-prefixed audiobook release files. Ebook/comic validation and
    # recursive import intentionally retain their existing hidden-file policy.
    files = source_manifest_children(source)
    files.reject! { |file| file.start_with?(".") } if readable_file_import?(book)
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
      ensure_real_import_directory!(entry.destination)
      import_audiobook_bundle_file(entry.source_path, entry.destination)
      entry.sidecar_paths.each do |sidecar|
        import_sidecar_file(sidecar, entry.destination, retry_safe: true)
      end
    end

    tracked_destination = plan.tracked_entry.destination
    ensure_real_import_directory!(tracked_destination)
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
      source_manifest_children(source_file).reject { |file| file.start_with?(".") }.each do |file|
        import_ebook_directory_entry(File.join(source_file, file), destination, book)
      end
    elsif allowed_ebook_import_file?(source_file) && ebook_file?(source_file)
      import_renamed_file(source_file, destination, book)
    elsif allowed_ebook_import_file?(source_file)
      import_sidecar_file(source_file, destination)
    else
      Rails.logger.info "[PostProcessingJob] Skipping one unsupported ebook import file"
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
    source_manifest_children(source).reject { |file| file.start_with?(".") }.flat_map do |file|
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
    head = nil
    File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
      stat = file.stat
      return false unless stat.file? && stat.size.positive?

      head = file.read([ 512, stat.size ].min)
    end
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
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENXIO, Errno::ENODEV, Errno::ENOTDIR
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
    # All sidecars now use retry-safe reconciliation; retain the keyword for
    # compatibility with bundle planner call sites.
    destination_file = File.join(destination, File.basename(source_file))
    import_file_without_duplicate_content(source_file, destination_file)
  end

  def import_renamed_file(source, destination, book)
    destination_file = renamed_destination_file(source, destination, book)
    Rails.logger.info "[PostProcessingJob] Applying the configured library filename template"
    destination_file = import_file_without_duplicate_content(source, destination_file)
    @imported_renamed_files << destination_file
    destination_file
  end

  def import_file(source, destination)
    if hardlink_completed_downloads?
      begin
        FileCopyService.hardlink_noreplace(
          source,
          destination,
          root: @import_base_path,
          source_root: @import_source_root,
          require_durable: @require_durable_import
        )
        @hardlinked_file_count += 1
      rescue FileCopyService::HardlinkUnsupportedError
        Rails.logger.warn(
          "[PostProcessingJob] Hardlink unavailable for one file; falling back to a retained-source copy"
        )
        FileCopyService.cp_noreplace(
          source,
          destination,
          root: @import_base_path,
          source_root: @import_source_root,
          hardlink_mode: true,
          allow_compatibility_fallback: true,
          require_durable: @require_durable_import
        )
        @hardlink_fallback_copied_count += 1
      end
    else
      FileCopyService.cp_noreplace(
        source,
        destination,
        root: @import_base_path,
        source_root: @import_source_root,
        source_snapshot: @import_source_file_snapshot,
        allow_compatibility_fallback: true,
        require_durable: @require_durable_import
      )
    end
    destination
  end

  def import_file_without_duplicate_content(source, destination)
    original_destination = destination
    FileCopyService.cleanup_interrupted_copies(
      File.dirname(original_destination),
      root: @import_base_path
    )

    loop do
      destination, already_imported = retry_safe_destination(source, original_destination)
      if already_imported
        if hardlink_completed_downloads?
          @reused_file_count += 1
        end
        verify_imported_destination!(
          source,
          destination,
          require_durable: @require_durable_import
        )
        record_imported_source!(source)
        Rails.logger.info "[PostProcessingJob] Reusing one identical previously imported file"
        return destination
      end

      imported = import_file(source, destination)
      verify_imported_destination!(source, imported, require_durable: true) if @require_durable_import
      record_imported_source!(source)
      return imported
    rescue Errno::EEXIST
      # Another importer won this candidate after retry_safe_destination.
      # Re-run content reconciliation before choosing a suffix.
      next
    end
  end

  def retry_safe_destination(source, destination)
    candidate = destination
    counter = 1

    loop do
      break unless path_occupied?(candidate)

      if !File.symlink?(candidate) && same_file_content?(source, candidate)
        unless hardlink_completed_downloads?
          return [ candidate, true ]
        end

        same_source_inode = FileCopyService.same_file_identity?(
          source,
          candidate,
          root: @import_base_path,
          source_root: @import_source_root,
          hardlink_mode: true
        )
        prior_fallback_copy = FileCopyService.secure_library_file_mode?(
          candidate,
          root: @import_base_path
        )
        if same_source_inode || prior_fallback_copy
          return [ candidate, true ]
        end
      end

      counter += 1
      candidate = duplicate_filename_candidate(destination, counter)
    end

    [ candidate, false ]
  end

  def same_file_content?(source, destination)
    FileCopyService.same_file_content?(
      source,
      destination,
      root: @import_base_path,
      source_root: @import_source_root,
      source_snapshot: @import_source_file_snapshot,
      hardlink_mode: hardlink_completed_downloads?
    )
  end

  def verify_imported_destination!(source, destination, require_durable:)
    snapshot = FileCopyService.verified_library_file_snapshot(
      source,
      destination,
      root: @import_base_path,
      source_root: @import_source_root,
      source_snapshot: @import_source_file_snapshot,
      hardlink_mode: hardlink_completed_downloads?,
      require_durable: require_durable
    )
    raise Errno::ESTALE, "library file changed after import" unless snapshot

    @verified_library_snapshots[Pathname(source).expand_path.to_s] << snapshot
  end

  def import_directory_entry(source, destination)
    stat = File.lstat(source)
    if stat.symlink?
      raise "Refusing to import symbolic link: #{source}"
    elsif stat.directory?
      nested_destination = File.join(destination, File.basename(source))
      ensure_real_import_directory!(nested_destination)
      source_manifest_children(source).each do |entry|
        import_directory_entry(File.join(source, entry), nested_destination)
      end
    elsif stat.file?
      import_file_without_duplicate_content(source, File.join(destination, File.basename(source)))
    else
      raise "Refusing to import non-regular path: #{source}"
    end
  rescue Errno::ENOENT, Errno::EACCES => e
    raise "Could not safely import #{source}: #{e.message}"
  end

  def ensure_real_import_directory!(path)
    FileCopyService.ensure_directory(path, root: @import_base_path, mode: 0o750)
  rescue FileCopyService::UnsafePathError, SystemCallError => error
    raise "Refusing to import into an unsafe directory: #{path}: #{error.message}"
  end

  def move_completed_downloads?
    completed_download_import_mode == "move"
  end

  def hardlink_completed_downloads?
    completed_download_import_mode == "hardlink"
  end

  def completed_download_import_mode
    return @completed_download_import_mode if defined?(@completed_download_import_mode)

    @completed_download_import_mode = SettingsService.get(
      :completed_download_import_mode,
      default: "copy"
    ).to_s
  end

  def remove_import_source(source_cleanup)
    return :complete unless source_cleanup

    removed = source_cleanup.fetch(:operation).call
    return :complete unless removed == false

    source_snapshot = source_cleanup.fetch(:source_snapshot)
    if source_snapshot && FileCopyService.source_file_quarantined?(source_snapshot)
      :retry
    else
      :retained
    end
  rescue => e
    Rails.logger.warn "[PostProcessingJob] Import-source cleanup failed: #{e.class}"
    :retry
  end

  def remove_import_source_file(source_snapshot, destination_snapshot)
    removed = FileCopyService.remove_source_file(
      source_snapshot,
      destination_snapshot: destination_snapshot
    )
    Rails.logger.warn "[PostProcessingJob] Source file changed; it was retained" unless removed
    removed
  end

  def remove_import_source_tree(source_root, imported_source_files, destination_snapshots)
    expected_files = source_root.entries.filter_map do |relative, manifest|
      relative if manifest[2] == :file
    end.sort
    unless imported_source_files.to_a.sort == expected_files
      Rails.logger.warn(
        "[PostProcessingJob] Source directory contains files that were not imported; it was retained"
      )
      return false
    end

    unless destination_snapshots_current?(destination_snapshots)
      Rails.logger.warn(
        "[PostProcessingJob] An imported library file changed; the source directory was retained"
      )
      return false
    end

    removed = FileCopyService.remove_source_tree(source_root)
    Rails.logger.warn "[PostProcessingJob] Source directory changed; it was retained" unless removed
    removed
  end

  def destination_snapshots_current?(snapshots)
    snapshots.all? do |snapshot|
      FileCopyService.file_snapshot_current?(snapshot, require_durable: true)
    end
  end

  def clear_source_cleanup_state(download, cleanup_state)
    Download.where(
      id: download.id,
      post_processing_cleanup_state: cleanup_state
    ).update_all(post_processing_cleanup_state: nil, updated_at: Time.current)
  end

  def source_manifest_children(directory)
    return Dir.children(directory).sort unless @import_source_root

    relative_directory = Pathname(directory).expand_path.relative_path_from(@import_source_root.path)
    if relative_directory.to_s != "."
      manifest = @import_source_root.entries[relative_directory.to_s]
      unless manifest && manifest[2] == :directory
        raise FileCopyService::UnsafePathError, "source directory is absent from the immutable manifest"
      end
    end

    @import_source_root.entries.keys.filter_map do |relative|
      path = Pathname(relative)
      path.basename.to_s if path.dirname == relative_directory
    end.uniq.sort
  rescue ArgumentError
    raise FileCopyService::UnsafePathError, "source directory escaped the immutable manifest"
  end

  def record_imported_source!(source)
    return unless @import_source_root

    relative = Pathname(source).expand_path.relative_path_from(@import_source_root.path)
    manifest = @import_source_root.entries[relative.to_s]
    unless manifest && manifest[2] == :file
      raise FileCopyService::UnsafePathError, "imported source is absent from the immutable manifest"
    end

    @imported_source_files << relative.to_s
  rescue ArgumentError
    raise FileCopyService::UnsafePathError, "imported source escaped the immutable manifest"
  end

  def renamed_destination_file(source, destination, book)
    extension = File.extname(source)
    new_filename = book ? PathTemplateService.build_filename(book, extension) : File.basename(source)
    destination_file = File.join(destination, new_filename)

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
      return { path: path, authorized_roots: [] }
    end

    Rails.logger.info "[PostProcessingJob] Resolving the download client path"

    candidates = build_path_candidates(path, download)
    candidates = deduplicate_path_candidates(candidates)

    # Return the first candidate that actually exists on disk.
    candidates.each do |candidate|
      next if candidate[:path].blank?

      if File.exist?(candidate[:path])
        Rails.logger.info "[PostProcessingJob] Path resolved via #{candidate[:strategy]}"
        return candidate
      end
    end

    # None found - log all candidates for debugging
    Rails.logger.warn(
      "[PostProcessingJob] No remapped path exists on disk; tried #{candidates.size} strategies"
    )

    # Return the first non-nil candidate so import_files produces a clear "not found" error
    best_guess = candidates.find { |c| c[:path].present? }
    best_guess || { path: path, authorized_roots: [] }
  end

  def build_path_candidates(path, download)
    candidates = []
    normalized_path = normalize_path_separators(path)
    remote_path = normalize_path_separators(SettingsService.get(:download_remote_path))
    local_path = normalize_path_separators(SettingsService.get(:download_local_path, default: "/downloads"))
    categories = category_path_variants(download.download_client&.category)
    client_download_path = normalize_path_separators(download.download_client&.download_path)
    basename = File.basename(normalized_path)
    original_path_roots = [ local_path, remote_path, client_download_path ].compact_blank

    # 1. Global remote_path → local_path prefix replacement
    if remote_path.present? && path_prefix_match?(normalized_path, remote_path)
      candidates << {
        strategy: "global_prefix_remap",
        path: replace_path_prefix(normalized_path, remote_path, local_path),
        authorized_roots: [ local_path ]
      }
    end

    # 2. local_path/category/basename — most common torrent client layout
    categories.each do |category|
      candidates << {
        strategy: "local_path_with_category",
        path: File.join(local_path, category, basename),
        authorized_roots: [ local_path ]
      }
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
          candidates << {
            strategy: "category_sibling_remap",
            path: File.join(File.dirname(local_path), relative_after_base),
            authorized_roots: [ File.dirname(local_path) ]
          }
        end
      end
    end

    # 4. Client download_path + basename
    if client_download_path.present?
      candidates << {
        strategy: "client_download_path",
        path: File.join(client_download_path, basename),
        authorized_roots: [ client_download_path ]
      }
    end

    # 5. local_path/basename (no category)
    candidates << {
      strategy: "local_path_basename",
      path: File.join(local_path, basename),
      authorized_roots: [ local_path ]
    }

    # 6. Original path as-is (works when download client runs in the same filesystem)
    candidates << {
      strategy: "original_path",
      path: path,
      authorized_roots: original_path_roots
    }

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
    "Source path not found. Verify path remapping settings " \
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

  def trigger_library_scan(book)
    lib_id = library_id_for(book)
    return unless lib_id.present?

    LibraryPlatformClient.scan_library(lib_id)
    Rails.logger.info "[PostProcessingJob] Triggered library scan for book ##{book.id}"
  rescue LibraryPlatformClient::Error => e
    Rails.logger.warn "[PostProcessingJob] Library scan failed for book ##{book.id}: #{e.class}"
    # Non-fatal - the library platform will pick up files on next auto-scan.
  end
end
