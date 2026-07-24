# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

# Crash-safe filesystem and Book ownership state for direct acquisitions.
# Network I/O and filesystem publication happen outside database transactions;
# a short, durable Book reservation prevents every acquisition pipeline from
# claiming the same title while publication is in progress.
class DirectDownloadFileService
  STAGING_DIRECTORY = ".shelfarr-staging"
  DIRECT_DOWNLOADS_DIRECTORY = "direct-downloads"
  ORPHAN_MAX_AGE = 24.hours
  ACTIVE_TIMEOUT = 30.minutes
  HEARTBEAT_INTERVAL = 10.seconds
  MANIFEST_MAX_BYTES = 10.megabytes

  class Error < StandardError; end
  class ConflictError < Error; end

  attr_reader :download, :book, :output_root, :destination_path, :book_path, :kind, :staging_path

  class << self
    def database_fingerprint
      Digest::SHA256.hexdigest(
        ActiveRecord::Base.connection_db_config.database.to_s
      ).first(12)
    end

    def staging_parent(root:)
      root = Pathname(root).expand_path
      directory = root.join(
        STAGING_DIRECTORY,
        DIRECT_DOWNLOADS_DIRECTORY,
        database_fingerprint
      )
      FileCopyService.secure_private_directory!(directory.to_s, root: root.to_s)
      directory
    rescue SystemCallError, FileCopyService::UnsafePathError => error
      raise Error, "Direct-download staging is not safely accessible: #{error.message}"
    end

    def reconcile!(download)
      download.reload
      return cleanup_completed_state!(download) if completed_publication?(download)

      if publication_complete?(download) && reservation_owned?(download)
        service_for(download).send(:finalize_database!, allow_failed: true)
        return cleanup_completed_state!(download.reload)
      end

      # A monitor can mark an apparently stalled worker failed while that
      # worker is paused in the kernel or on slow storage. The status change
      # itself renews this lease, so recovery must not remove its staging tree
      # or reservation until a full timeout has elapsed. A complete atomic
      # publication is still safe to finalize above during the grace period.
      return false if recovery_lease_fresh?(download)
      return false unless valid_output_root_identity?(download)

      cleanup_staging_and_state!(download, release_reservation: true)
      false
    rescue ActiveRecord::RecordNotFound
      false
    end

    def cleanup_orphans!(root:, max_age: ORPHAN_MAX_AGE.ago)
      parent = staging_parent(root: root)
      referenced = Download.where.not(direct_staging_path: nil).pluck(:direct_staging_path).to_set
      removed = 0

      FileCopyService.directory_children(parent.to_s, root: root).each do |child|
        next unless child.name.start_with?("download-")
        next unless child.type == :directory && child.mtime <= max_age

        path = parent.join(child.name)
        next if referenced.include?(path.to_s)

        removed += 1 if FileCopyService.remove_directory_child_if_identity(
          parent.to_s,
          child.name,
          root: root,
          device: child.device,
          inode: child.inode
        )
      rescue Errno::ENOENT, Errno::EACCES, FileCopyService::UnsafePathError
        next
      end
      removed
    rescue Error, Errno::ENOENT
      0
    end

    def output_roots
      configured = [
        SettingsService.get(:ebook_output_path, default: "/ebooks"),
        SettingsService.get(:audiobook_output_path, default: "/audiobooks")
      ].compact_blank
      persisted = Download.where.not(direct_output_root: nil).distinct.pluck(:direct_output_root)
      (configured + persisted).map { |root| Pathname(root).expand_path.to_s }.uniq
    end

    private

    def service_for(download)
      new(
        download: download,
        book: download.request.book,
        output_root: download.direct_output_root,
        destination_path: download.direct_destination_path,
        book_path: download.direct_book_path,
        kind: download.direct_publication_kind
      )
    end

    def recovery_lease_fresh?(download)
      download.download_type == "direct" && download.direct_staging_path.present? &&
        download.updated_at > ACTIVE_TIMEOUT.ago
    end

    def reservation_owned?(download)
      token = download.direct_reservation_token
      return false if token.blank?

      Book.where(
        id: download.request.book_id,
        acquisition_reservation_token: token,
        acquisition_reservation_owner_type: "Download",
        acquisition_reservation_owner_id: download.id
      ).exists?
    end

    def completed_publication?(download)
      download.completed? && download.direct_book_path.present? &&
        download.request.book.file_path == download.direct_book_path
    end

    def publication_complete?(download)
      return false if download.direct_content_manifest.blank?
      return false if download.direct_destination_path.blank? || download.direct_output_root.blank?
      return false unless valid_output_root_identity?(download)

      expected = JSON.parse(download.direct_content_manifest)
      actual = if download.direct_publication_kind == "directory"
        FileCopyService.directory_content_manifest(
          download.direct_destination_path,
          root: download.direct_output_root
        )
      else
        FileCopyService.file_content_manifest(
          download.direct_destination_path,
          root: download.direct_output_root
        )
      end
      actual == expected
    rescue JSON::ParserError, SystemCallError, FileCopyService::UnsafePathError
      false
    end

    def release_reservation!(download)
      token = download.direct_reservation_token
      return if token.blank?

      Book.where(
        id: download.request.book_id,
        acquisition_reservation_token: token,
        acquisition_reservation_owner_type: "Download",
        acquisition_reservation_owner_id: download.id
      ).update_all(
        acquisition_reservation_token: nil,
        acquisition_reservation_owner_type: nil,
        acquisition_reservation_owner_id: nil,
        updated_at: Time.current
      )
      Download.where(id: download.id, direct_reservation_token: token).update_all(
        direct_reservation_token: nil,
        updated_at: Time.current
      )
    end

    def cleanup_completed_state!(download)
      cleanup_staging_and_state!(download)
      true
    end

    def cleanup_staging_and_state!(download, release_reservation: false)
      return false unless remove_staging!(download)

      release_reservation!(download) if release_reservation
      Download.where(id: download.id).update_all(recovery_state_attributes)
      true
    end

    def remove_staging!(download)
      path = download.direct_staging_path
      return true if path.blank?
      return false if download.direct_output_root.blank?
      return false unless valid_output_root_identity?(download)

      File.lstat(path)

      parent = staging_parent(root: download.direct_output_root)
      expanded = Pathname(path).expand_path
      return false unless expanded.parent == parent

      snapshot = FileCopyService.snapshot_source_root(expanded)
      expected_identity = [ download.direct_staging_device, download.direct_staging_inode ]
      return false unless [ snapshot.device, snapshot.inode ] == expected_identity

      FileCopyService.remove_source_tree(snapshot)
    rescue Errno::ENOENT
      valid_output_root_identity?(download) && valid_staging_parent_identity?(download)
    rescue Error, SystemCallError, FileCopyService::UnsafePathError
      false
    end

    def valid_output_root_identity?(download)
      return false if download.direct_output_root_device.blank? || download.direct_output_root_inode.blank?

      stat = File.lstat(Pathname(download.direct_output_root).realpath)
      [ stat.dev, stat.ino ] == [ download.direct_output_root_device, download.direct_output_root_inode ]
    rescue SystemCallError
      false
    end

    def valid_staging_parent_identity?(download)
      return false if download.direct_staging_path.blank?
      if download.direct_staging_parent_device.blank? || download.direct_staging_parent_inode.blank?
        return false
      end

      parent = Pathname(download.direct_staging_path).expand_path.parent
      FileCopyService.directory_identity(parent.to_s, root: download.direct_output_root) ==
        [ download.direct_staging_parent_device, download.direct_staging_parent_inode ]
    rescue SystemCallError, FileCopyService::UnsafePathError
      false
    end

    def recovery_state_attributes
      {
        direct_reservation_token: nil,
        direct_staging_path: nil,
        direct_staging_device: nil,
        direct_staging_inode: nil,
        direct_staging_parent_device: nil,
        direct_staging_parent_inode: nil,
        direct_destination_path: nil,
        direct_book_path: nil,
        direct_output_root: nil,
        direct_output_root_device: nil,
        direct_output_root_inode: nil,
        direct_publication_kind: nil,
        direct_content_manifest: nil,
        updated_at: Time.current
      }
    end
  end

  def initialize(download:, book:, output_root:, destination_path:, book_path:, kind:)
    @download = download
    @book = book
    @output_root = Pathname(output_root).expand_path.to_s
    @destination_path = Pathname(destination_path).expand_path.to_s
    @book_path = Pathname(book_path).expand_path.to_s
    @kind = kind.to_s
    raise Error, "Unsupported direct publication kind" unless @kind.in?(%w[file directory])

    validate_destination_paths!
  end

  def create_staging!
    parent = self.class.staging_parent(root: output_root)
    output_root_stat = File.lstat(Pathname(output_root).realpath)
    @output_root_device = output_root_stat.dev
    @output_root_inode = output_root_stat.ino
    created = FileCopyService.create_private_directory(
      parent.to_s,
      root: output_root,
      prefix: "download-#{download.id}-"
    )
    @staging_path = created.name
    @staging_device = created.device
    @staging_inode = created.inode

    persisted = Download.where(
      id: download.id,
      status: Download.statuses[:downloading],
      download_type: "direct"
    ).update_all(
      direct_staging_path: @staging_path,
      direct_staging_device: created.device,
      direct_staging_inode: created.inode,
      direct_staging_parent_device: created.parent_device,
      direct_staging_parent_inode: created.parent_inode,
      direct_destination_path: destination_path,
      direct_book_path: book_path,
      direct_output_root: output_root,
      direct_output_root_device: output_root_stat.dev,
      direct_output_root_inode: output_root_stat.ino,
      direct_publication_kind: kind,
      direct_content_manifest: nil,
      updated_at: Time.current
    )
    raise Error, "Direct download is no longer active" unless persisted == 1

    download.reload
    @staging_path
  rescue
    cleanup_unpersisted_staging!
    raise
  end

  def publish_file_and_finalize!(source)
    expected = digest_io(source)
    persist_manifest!(expected)
    reserve_book!
    ensure_output_root_identity!
    ensure_destination_parent!
    ensure_output_root_identity!
    @publication_started = true
    begin
      FileCopyService.cp_io_noreplace(
        source,
        destination_path,
        root: output_root,
        heartbeat: method(:refresh_heartbeat!)
      )
    rescue Errno::EEXIST
      unless FileCopyService.file_content_manifest(
        destination_path,
        root: output_root,
        heartbeat: method(:refresh_heartbeat!)
      ) == expected
        raise ConflictError, "A different library file already exists; it was preserved"
      end
    end
    ensure_publication_verified!
    finalize_database!
  rescue => error
    return true if recover_after_publication_error!(error)

    raise
  end

  def publish_directory_and_finalize!(source_directory)
    expected = FileCopyService.directory_content_manifest(
      source_directory,
      root: staging_path,
      heartbeat: method(:refresh_heartbeat!)
    )
    persist_manifest!(expected)
    reserve_book!
    ensure_output_root_identity!
    ensure_destination_parent!
    source_snapshot = FileCopyService.snapshot_source_root(
      source_directory,
      heartbeat: method(:refresh_heartbeat!)
    )
    ensure_output_root_identity!
    @publication_started = true
    begin
      FileCopyService.mv_directory_noreplace(
        source_directory,
        destination_path,
        root: output_root,
        source_root: source_snapshot,
        heartbeat: method(:refresh_heartbeat!)
      )
    rescue Errno::EEXIST
      unless FileCopyService.directory_content_manifest(
        destination_path,
        root: output_root,
        heartbeat: method(:refresh_heartbeat!)
      ) == expected
        raise ConflictError, "A different audiobook directory already exists; it was preserved"
      end
    end
    ensure_publication_verified!
    finalize_database!
  rescue => error
    return true if recover_after_publication_error!(error)

    raise
  end

  def cleanup_after_run!
    download.reload
    return false if download.direct_reservation_token.present? && !download.completed?

    self.class.send(:cleanup_staging_and_state!, download)
  end

  private

  def validate_destination_paths!
    root = Pathname(output_root)
    [ destination_path, book_path ].each do |raw_path|
      relative = Pathname(raw_path).relative_path_from(root)
      if relative.to_s == ".." || relative.to_s.start_with?("..#{File::SEPARATOR}")
        raise Error, "Direct-download destination is outside the configured library root"
      end
    rescue ArgumentError
      raise Error, "Direct-download destination is outside the configured library root"
    end
  end

  def persist_manifest!(manifest)
    payload = JSON.generate(manifest)
    if payload.bytesize > MANIFEST_MAX_BYTES
      raise Error, "Direct-download publication manifest is too large"
    end

    updated = Download.where(
      id: download.id,
      status: Download.statuses[:downloading],
      download_type: "direct",
      direct_staging_path: staging_path
    ).update_all(direct_content_manifest: payload, updated_at: Time.current)
    raise Error, "Direct download is no longer active" unless updated == 1

    download.reload
  end

  def reserve_book!
    token = SecureRandom.hex(32)
    ActiveRecord::Base.transaction do
      current_download = Download.lock.find(download.id)
      unless current_download.downloading? && current_download.download_type == "direct" &&
          current_download.direct_staging_path == staging_path
        raise Error, "Direct download is no longer active"
      end

      claimed = Book.where(id: book.id)
        .where("file_path IS NULL OR TRIM(file_path) = ''")
        .where(acquisition_reservation_token: nil)
        .update_all(
          acquisition_reservation_token: token,
          acquisition_reservation_owner_type: "Download",
          acquisition_reservation_owner_id: download.id,
          updated_at: Time.current
        )
      raise ConflictError, "Another acquisition already claimed this title" unless claimed == 1

      current_download.update!(direct_reservation_token: token)
    end
    download.reload
    token
  end

  def finalize_database!(allow_failed: false)
    ensure_publication_verified!
    ActiveRecord::Base.transaction do
      current_download = Download.lock.find(download.id)
      current_book = Book.lock.find(book.id)
      current_request = current_download.request.lock!
      token = current_download.direct_reservation_token

      if current_download.completed? && current_book.file_path == book_path
        return true
      end
      valid_status = current_download.downloading? || (allow_failed && current_download.failed?)
      unless valid_status && current_download.download_type == "direct" && token.present?
        raise Error, "Direct download no longer owns its completion"
      end
      unless current_book.acquisition_reservation_token == token &&
          current_book.acquisition_reservation_owner_type == "Download" &&
          current_book.acquisition_reservation_owner_id == current_download.id
        raise ConflictError, "Another acquisition owns this title"
      end
      unless self.class.send(:valid_output_root_identity?, current_download)
        raise Error, "Direct-download output root changed before database completion"
      end

      current_book.update!(
        file_path: book_path,
        acquisition_reservation_token: nil,
        acquisition_reservation_owner_type: nil,
        acquisition_reservation_owner_id: nil
      )
      current_download.update!(status: :completed, download_path: destination_path)
      current_request.complete!
      unless self.class.send(:valid_output_root_identity?, current_download)
        raise Error, "Direct-download output root changed during database completion"
      end
    end
    download.reload
    true
  end

  def recover_after_publication_error!(error)
    download.reload
    if self.class.send(:publication_complete?, download) &&
        self.class.send(:reservation_owned?, download)
      return finalize_database!(allow_failed: true)
    end

    return false unless self.class.send(:valid_output_root_identity?, download)
    return false if @publication_started && !error.is_a?(ConflictError)

    self.class.send(:release_reservation!, download)
    download.reload
    false
  rescue ActiveRecord::RecordNotFound
    false
  end

  def ensure_destination_parent!
    FileCopyService.ensure_directory(
      File.dirname(destination_path),
      root: output_root
    )
  end

  def ensure_output_root_identity!
    download.reload
    return true if self.class.send(:valid_output_root_identity?, download)

    raise Error, "Direct-download output root changed during publication"
  end

  def ensure_publication_verified!
    download.reload
    return true if self.class.send(:publication_complete?, download)

    raise Error, "Direct-download publication could not be verified"
  end

  def digest_io(source)
    position = source.pos
    source.rewind
    digest = Digest::SHA256.new
    buffer = +""
    while source.read(FileCopyService::BUFFER_SIZE, buffer)
      digest << buffer
      refresh_heartbeat!
    end
    [ "file", source.stat.size, digest.hexdigest ]
  ensure
    source.seek(position) if position
  end

  def refresh_heartbeat!
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if @last_heartbeat_at && now - @last_heartbeat_at < HEARTBEAT_INTERVAL.to_f

    updated = Download.where(
      id: download.id,
      status: Download.statuses[:downloading],
      download_type: "direct",
      direct_staging_path: staging_path
    ).update_all(updated_at: Time.current)
    raise Error, "Direct download is no longer active" unless updated == 1

    @last_heartbeat_at = now
  end

  def cleanup_unpersisted_staging!
    return if @staging_path.blank? || @staging_device.blank? || @staging_inode.blank?

    root_stat = File.lstat(Pathname(output_root).realpath)
    return unless [ root_stat.dev, root_stat.ino ] == [ @output_root_device, @output_root_inode ]

    parent = self.class.staging_parent(root: output_root)
    expanded = Pathname(@staging_path).expand_path
    return unless expanded.parent == parent

    FileCopyService.remove_directory_child_if_identity(
      parent.to_s,
      expanded.basename.to_s,
      root: output_root,
      device: @staging_device,
      inode: @staging_inode
    )
  rescue Error, SystemCallError, FileCopyService::UnsafePathError
    nil
  end
end
