# frozen_string_literal: true

require "pathname"
require "find"

class OwnedMediaBackupJob < ApplicationJob
  class BackupError < StandardError; end

  POLL_INTERVAL = 15.seconds
  QUEUED_POLL_INTERVAL = 1.minute
  TRANSIENT_POLL_INTERVAL = 1.minute
  MAX_BACKUP_RUNTIME = 12.hours
  MAX_QUEUE_WAIT = 7.days
  MAX_COMPANION_START_ATTEMPTS = 3
  UPLOAD_PROCESSING_RECOVERY_GRACE_PERIOD = 30.minutes
  JOB_CONCURRENCY_LEASE = 30.minutes
  COMPANION_DATA_ROOT = Pathname("/data").freeze
  DEFAULT_IMPORT_ROOT = "/imports/libation"
  AUDIO_EXTENSIONS = %w[.m4b .m4a .mp3].freeze
  MAX_DIRECTORY_ENTRIES = 10_000

  queue_as :default
  limits_concurrency to: 1,
    key: ->(owned_media_import_id, *) { "owned-media-backup-#{owned_media_import_id}" },
    duration: JOB_CONCURRENCY_LEASE

  class << self
    def upload_processing_job_pending?(upload_id)
      return false unless solid_queue_adapter?

      SolidQueue::Job
        .where(class_name: UploadProcessingJob.name, finished_at: nil)
        .where.missing(:failed_execution)
        .any? do |job|
          Array(job.arguments["arguments"]).first.to_i == upload_id.to_i
        end
    rescue StandardError => error
      # The durable backup poll will inspect the upload again. When queue state
      # cannot be read, skipping one enqueue is safer than amplifying work.
      Rails.logger.warn(
        "[OwnedMediaBackupJob] Could not inspect upload-processing jobs for " \
          "upload ##{upload_id}: #{error.class}"
      )
      true
    end

    private

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end

  def perform(owned_media_import_id, poll_token = nil)
    database_logger = ActiveRecord::Base.logger
    if database_logger&.respond_to?(:silence)
      database_logger.silence(Logger::INFO) do
        perform_with_database_privacy(owned_media_import_id, poll_token)
      end
    else
      perform_with_database_privacy(owned_media_import_id, poll_token)
    end
  end

  private

  # Artifact paths and companion diagnostics are persisted on the import and
  # upload records. Active Record DEBUG binds would expose those values, so
  # suppress only SQL DEBUG while retaining identifier-only INFO+ operations.
  def perform_with_database_privacy(owned_media_import_id, poll_token)
    media_import = OwnedMediaImport.includes(
      owned_library_item: :owned_library_connection
    ).find_by(id: owned_media_import_id)
    return unless media_import

    @poll_token = media_import.claim_poll_token(poll_token)
    return unless @poll_token

    if media_import.upload.present?
      poll_upload(media_import)
    elsif media_import.external_job_id.present?
      poll_companion_job(media_import)
    else
      start_backup(media_import)
    end
  rescue LibationCompanionClient::ConnectionError, LibationCompanionClient::BusyError => e
    if media_import&.active? && media_import.reload.external_job_id.present?
      retry_transient_companion_poll(media_import, e)
    elsif media_import&.active?
      retry_transient_companion_start(media_import, e)
    else
      mark_failed(media_import, e.message)
      raise
    end
  rescue LibationCompanionClient::Error, OwnedMediaImportFileService::Error, BackupError => e
    mark_failed(media_import, e.message)
    raise
  rescue StandardError => e
    mark_failed(media_import, "Unexpected #{e.class} while importing the Libation backup")
    raise
  end

  def start_backup(media_import)
    item = media_import.owned_library_item
    connection = item.owned_library_connection

    raise BackupError, "Audible Backup is disabled" unless connection.enabled?
    raise BackupError, "This title is no longer present in the Audible library" unless item.active?
    unless item.purchased?
      raise BackupError, "Only titles confirmed as purchased are eligible for backup"
    end
    raise BackupError, "A requesting user is required to import this backup" unless media_import.requested_by
    local_resolution = OwnedLibraryBookMatcher.new.resolve(item)
    if item.book&.reload&.acquisition_blocked? || local_resolution.matched?
      raise BackupError, "This title is already available in the Shelfarr library"
    end
    if local_resolution.conflict? && !media_import.separate_edition?
      raise BackupError, "A possible local-library match must be reviewed before this title can be backed up"
    end
    raise BackupError, "Libation backup waited more than 7 days to start" if queue_wait_expired?(media_import)

    OwnedMediaImportFileService.verify_filesystem_capabilities!

    return unless claim_companion_start_attempt(media_import)

    companion_job = connection.client.start_backup(item.external_id)
    return unless attach_companion_job(media_import, companion_job.id)

    handle_companion_job(media_import, companion_job)
  end

  def poll_companion_job(media_import)
    companion_job = media_import.owned_library_item.owned_library_connection.client.job(
      media_import.external_job_id
    )
    handle_companion_job(media_import, companion_job)
  end

  def handle_companion_job(media_import, companion_job)
    if companion_job.completed?
      stage_completed_artifact(media_import, companion_job)
    elsif companion_job.failed? || companion_job.cancelled?
      raise BackupError, companion_job.error.presence || "Libation backup #{companion_job.status}"
    elsif companion_job.status == "queued"
      raise BackupError, "Libation backup stayed queued for more than 7 days" if queue_wait_expired?(media_import)

      unless media_import.queued? && media_import.started_at.nil? && media_import.error_message.nil?
        return unless update_active_import(
          media_import,
          status: "queued",
          started_at: nil,
          error_message: nil
        )
      end

      schedule_poll(media_import, wait: QUEUED_POLL_INTERVAL)
    else
      unless media_import.downloading? && media_import.started_at.present? && media_import.error_message.nil?
        return unless update_active_import(
          media_import,
          status: "downloading",
          started_at: media_import.started_at || Time.current,
          error_message: nil
        )
      end
      raise BackupError, "Libation backup timed out" if backup_expired?(media_import)

      schedule_poll(media_import)
    end
  end

  def stage_completed_artifact(media_import, companion_job)
    with_artifact_staging_lock(media_import) do |staging_root|
      OwnedMediaImportFileService.verify_filesystem_capabilities!(root: staging_root)
      media_import.reload
      return unless current_poll?(media_import)
      return if media_import.upload.present?

      paths = companion_job.artifact_paths
      if paths.empty?
        library_entry = media_import.owned_library_item.owned_library_connection.client.library.find do |entry|
          entry.external_id == media_import.owned_library_item.external_id
        end
        paths = [ library_entry&.file_path ].compact
      end

      source_path = select_audio_artifact(paths)
      # Rotate the durable polling token and queue its recovery check before
      # staging. Redeliveries carrying the old token become no-ops, while this
      # watchdog can resume a pending upload after a hard worker exit.
      return unless schedule_poll(media_import)

      upload = create_and_attach_upload(media_import, source_path, staging_root: staging_root)
      return unless upload

      enqueue_upload_processing(upload)
    end
  end

  def poll_upload(media_import)
    return unless current_poll?(media_import.reload)

    upload = media_import.upload.reload

    if upload.completed?
      complete_import(media_import, upload)
    elsif upload.failed?
      raise BackupError, upload.error_message.presence || "Shelfarr could not import the Libation backup"
    else
      if recover_stale_upload(upload)
        # A worker may have been killed after atomically finalizing the file but
        # before SQLite committed. Give that one durable reconciliation attempt
        # a fresh bounded processing window before applying the phase timeout.
        recovery_granted = grant_upload_recovery_window(media_import)
        if !recovery_granted && backup_expired?(media_import.reload)
          raise BackupError, "Shelfarr import of the Libation backup timed out"
        end
      elsif backup_expired?(media_import)
        raise BackupError, "Shelfarr import of the Libation backup timed out"
      end

      upload.reload
      enqueue_upload_processing(upload) if upload.pending?

      schedule_poll(media_import)
    end
  end

  def complete_import(media_import, upload)
    now = Time.current
    completed = false
    media_import.transaction do
      media_import.lock!
      next unless current_poll?(media_import)

      media_import.update!(status: "completed", completed_at: now, error_message: nil)
      media_import.owned_library_item.update!(
        book: upload.book,
        downloaded: true,
        backed_up_at: now,
        file_path: upload.book&.file_path
      )
      completed = true
    end
    completed
  end

  def create_and_attach_upload(media_import, source_path, staging_root:)
    # Keep the staged copy on the persistent audiobook filesystem. Finalizing
    # it later is a same-filesystem atomic handoff and survives a Rails
    # container replacement. A deterministic path lets redelivery replace an
    # incomplete copy left by a hard worker exit before the database attach.
    destination = nil
    destination_size = nil
    artifact_path = nil
    with_secure_audio_artifact(source_path) do |source, resolved_path|
      destination, destination_size = OwnedMediaImportFileService.copy_io_to_staging!(
        media_import,
        source,
        source_path.extname,
        root: staging_root
      )
      artifact_path = resolved_path
    end
    upload = nil
    media_import.transaction do
      media_import.lock!
      next unless current_poll?(media_import)

      upload = Upload.create!(
        user: media_import.requested_by,
        book: media_import.owned_library_item.book,
        request: media_import.request,
        original_filename: artifact_path.basename.to_s,
        file_path: destination,
        file_size: destination_size,
        content_type: content_type_for(File.extname(destination)),
        status: :pending
      )
      media_import.update!(
        upload: upload,
        status: "processing",
        artifact_path: artifact_path.to_s,
        started_at: media_import.started_at || Time.current,
        error_message: nil
      )
    end
    return unless upload

    upload
  end

  def with_secure_audio_artifact(source_path)
    candidate = Pathname(source_path).expand_path
    root = import_root.realpath
    unless path_within_root?(candidate, root)
      raise BackupError, "Libation artifact resolves outside the configured import root"
    end

    File.open(candidate.to_s, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |source|
      source_stat = source.stat
      unless source_stat.file?
        raise BackupError, "Libation artifact is not a regular audiobook file"
      end

      # Re-resolve both paths after opening, then prove the pathname still
      # identifies the held descriptor. The descriptor remains authoritative
      # if the shared path is changed after this point.
      current_root = import_root.realpath
      resolved_path = candidate.realpath
      path_stat = resolved_path.stat
      unless path_within_root?(resolved_path, current_root)
        raise BackupError, "Libation artifact resolves outside the configured import root"
      end
      unless same_file_identity?(source_stat, path_stat)
        raise BackupError, "Libation artifact changed while Shelfarr was opening it"
      end

      yield source, resolved_path
    end
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENXIO, Errno::ENODEV
    raise BackupError, "Libation artifact is not accessible from Shelfarr"
  end

  def path_within_root?(path, root)
    path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
  end

  def same_file_identity?(left, right)
    left.dev == right.dev && left.ino == right.ino
  end

  def select_audio_artifact(raw_paths)
    raise BackupError, "Libation completed without reporting an artifact" if raw_paths.empty?

    candidates = raw_paths.flat_map do |raw_path|
      resolved = resolve_artifact_path(raw_path)
      resolved.directory? ? audio_files_in(resolved) : [ resolved ]
    end.uniq
    candidates.select! { |path| AUDIO_EXTENSIONS.include?(path.extname.downcase) }

    raise BackupError, "Libation did not report a supported audiobook file" if candidates.empty?

    AUDIO_EXTENSIONS.each do |extension|
      matches = candidates.select { |path| path.extname.casecmp?(extension) }
      return matches.first if matches.one?
      if matches.many?
        raise BackupError, "Libation reported multiple #{extension.delete_prefix('.').upcase} files; a single primary artifact is required"
      end
    end

    raise BackupError, "Libation did not report a single primary audiobook artifact"
  end

  def audio_files_in(directory)
    files = []
    entries_seen = 0
    Find.find(directory.to_s) do |entry|
      next if entry == directory.to_s

      entries_seen += 1
      if entries_seen > MAX_DIRECTORY_ENTRIES
        raise BackupError, "Libation artifact directory contains too many files"
      end

      path = Pathname(entry)
      next unless path.file?

      files << validate_resolved_path(path)
    end
    files
  end

  def resolve_artifact_path(raw_path)
    value = raw_path.to_s.strip
    raise BackupError, "Libation reported an empty artifact path" if value.blank?

    path = Pathname(value)
    relative_path = if path.absolute?
      unless path == COMPANION_DATA_ROOT || path.to_s.start_with?("#{COMPANION_DATA_ROOT}/")
        raise BackupError, "Libation reported an artifact outside its data directory"
      end

      path.relative_path_from(COMPANION_DATA_ROOT)
    else
      path
    end

    validate_resolved_path(import_root.join(relative_path).cleanpath)
  rescue ArgumentError
    raise BackupError, "Libation reported an invalid artifact path"
  end

  def validate_resolved_path(path)
    root = import_root.realpath
    resolved = path.realpath
    unless resolved == root || resolved.to_s.start_with?("#{root}#{File::SEPARATOR}")
      raise BackupError, "Libation artifact resolves outside the configured import root"
    end

    resolved
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise BackupError, "Libation artifact is not accessible from Shelfarr"
  end

  def import_root
    @import_root ||= Pathname(
      ENV.fetch("SHELFARR_LIBATION_IMPORT_ROOT", DEFAULT_IMPORT_ROOT)
    ).expand_path
  end

  def content_type_for(extension)
    case extension.downcase
    when ".mp3"
      "audio/mpeg"
    when ".m4a", ".m4b"
      "audio/mp4"
    else
      "application/octet-stream"
    end
  end

  def attach_companion_job(media_import, external_job_id)
    attached = false
    media_import.transaction do
      media_import.lock!
      next unless current_poll?(media_import)

      existing = OwnedMediaImport.lock.find_by(external_job_id: external_job_id)
      if existing && existing.id != media_import.id
        unless existing.terminal? &&
            existing.owned_library_item_id == media_import.owned_library_item_id
          raise BackupError, "Libation returned a job already attached to another active backup"
        end

        existing.update!(external_job_id: nil)
      end
      media_import.update!(external_job_id: external_job_id)
      attached = true
    end
    attached
  end

  def with_artifact_staging_lock(media_import)
    root = OwnedMediaImportFileService.output_root
    OwnedMediaImportFileService.with_lock(root, "import-#{media_import.id}") do
      yield root
    end
  end

  def grant_upload_recovery_window(media_import)
    media_import.with_lock do
      media_import.reload
      next false unless current_poll?(media_import)
      next false if media_import.upload_recovery_attempts.positive?

      media_import.update!(
        upload_recovery_attempts: 1,
        started_at: Time.current,
        error_message: nil
      )
      true
    end
  end

  def retry_transient_companion_poll(media_import, error)
    if (media_import.started_at.nil? && queue_wait_expired?(media_import)) ||
        (media_import.started_at.present? && backup_expired?(media_import))
      message = if media_import.started_at.nil?
        "The Libation companion remained unavailable for more than 7 days"
      else
        "The Libation backup stopped reporting progress for more than 12 hours"
      end
      mark_failed(media_import, message)
      raise BackupError, message
    end

    Rails.logger.warn(
      "[OwnedMediaBackupJob] Companion poll for import ##{media_import.id} " \
        "temporarily failed with #{error.class}; retrying"
    )
    updated = update_active_import(
      media_import,
      error_message: "The Libation companion is temporarily unavailable; Shelfarr will retry automatically."
    ) { media_import.external_job_id.present? }
    return unless updated

    schedule_poll(media_import, wait: TRANSIENT_POLL_INTERVAL)
  rescue BackupError => enqueue_error
    mark_failed(media_import, enqueue_error.message)
    raise
  end

  def retry_transient_companion_start(media_import, error)
    media_import.reload
    if queue_wait_expired?(media_import) ||
        media_import.companion_start_attempts >= MAX_COMPANION_START_ATTEMPTS
      message = "Shelfarr could not confirm the Libation backup after " \
        "#{media_import.companion_start_attempts} attempts"
      mark_failed(media_import, message)
      raise BackupError, message
    end

    Rails.logger.warn(
      "[OwnedMediaBackupJob] Companion start for import ##{media_import.id} " \
        "temporarily failed with #{error.class}; retrying idempotently"
    )
    updated = update_active_import(
      media_import,
      error_message: "Shelfarr could not confirm whether Libation accepted the backup; " \
        "it will retry automatically."
    ) do
      media_import.external_job_id.blank? &&
        media_import.companion_start_attempts < MAX_COMPANION_START_ATTEMPTS &&
        !queue_wait_expired?(media_import)
    end
    return unless updated

    schedule_poll(media_import, wait: TRANSIENT_POLL_INTERVAL)
  rescue BackupError => enqueue_error
    mark_failed(media_import, enqueue_error.message)
    raise
  end

  def claim_companion_start_attempt(media_import)
    media_import.with_lock do
      media_import.reload
      next false unless current_poll?(media_import)
      if media_import.companion_start_attempts >= MAX_COMPANION_START_ATTEMPTS
        raise BackupError, "Shelfarr exhausted its Libation backup start retries"
      end

      media_import.update!(
        status: "starting",
        started_at: nil,
        error_message: nil,
        companion_start_attempts: media_import.companion_start_attempts + 1
      )
      true
    end
  end

  def update_active_import(media_import, attributes)
    media_import.with_lock do
      media_import.reload
      next false unless current_poll?(media_import)
      next false if block_given? && !yield

      media_import.update!(attributes)
      true
    end
  end

  def recover_stale_upload(upload)
    upload.with_lock do
      upload.reload
      next false unless upload.processing?
      next false unless upload.updated_at <= UPLOAD_PROCESSING_RECOVERY_GRACE_PERIOD.ago

      upload.update!(status: :pending, error_message: nil)
      true
    end
  end

  def schedule_poll(media_import, wait: POLL_INTERVAL)
    next_token = OwnedMediaImport.next_poll_token(@poll_token)
    job = self.class.set(wait: wait).perform_later(media_import.id, next_token)
    unless job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
      raise BackupError, "Shelfarr could not queue the next Libation backup check"
    end

    # Usually the current worker promotes the successor immediately. If it is
    # killed after enqueueing but before this line, the successor job can
    # atomically self-promote the same deterministic token when it starts.
    promoted_token = media_import.claim_poll_token(next_token)
    promoted = promoted_token == next_token
    @poll_token = next_token if promoted
    promoted
  end

  def enqueue_upload_processing(upload)
    upload.with_lock do
      upload.reload
      return true unless upload.pending?
      return true if self.class.upload_processing_job_pending?(upload.id)

      job = UploadProcessingJob.perform_later(upload.id)
      return true if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
    end

    Rails.logger.warn(
      "[OwnedMediaBackupJob] Upload processing for upload ##{upload.id} was not enqueued; " \
        "the durable backup poll will retry"
    )
    false
  rescue StandardError => error
    Rails.logger.warn(
      "[OwnedMediaBackupJob] Upload processing enqueue for upload ##{upload.id} " \
        "failed with #{error.class}; the durable backup poll will retry"
    )
    false
  end

  def backup_expired?(media_import)
    media_import.started_at.blank? || media_import.started_at <= MAX_BACKUP_RUNTIME.ago
  end

  def queue_wait_expired?(media_import)
    (media_import.dispatched_at || media_import.created_at) <= MAX_QUEUE_WAIT.ago
  end

  def current_poll?(media_import)
    media_import.active? && media_import.poll_token_matches?(@poll_token)
  end

  def mark_failed(media_import, message)
    return false unless media_import && @poll_token.present?

    media_import.mark_failed!(message, poll_token: @poll_token)
  end
end
