# frozen_string_literal: true

# Routes a completed book into a requesting user's personal output directory.
# Called after the canonical system copy is finalized. Supports two modes:
#   copy     — duplicates files into the user's directory and records the path
#   hardlink — creates hard links (zero extra storage) into the user's directory
#
# Hard links share the same disk bytes as the canonical copy. They cannot span
# filesystem boundaries (EXDEV), so we fall back to a full copy in that case.
# Directories cannot be hard-linked; we walk each file individually instead.
class UserLibraryRoutingService
  VALID_MODES = %w[copy hardlink].freeze

  def self.call(book:, request:)
    new(book: book, request: request).call
  end

  def initialize(book:, request:)
    @book = book
    @request = request
    @user = request.user
  end

  def call
    return unless routing_configured?
    return unless @book.file_path.present?

    source = @book.file_path
    destination = build_user_destination(source)

    case @user.library_routing_mode
    when "copy"
      perform_copy(source, destination)
    when "hardlink"
      perform_hardlink(source, destination)
    end

    record_user_path(destination)
  rescue => e
    Rails.logger.warn(
      "[UserLibraryRoutingService] Routing failed for user ##{@user.id}, book ##{@book.id}: " \
        "#{e.class}: #{e.message}"
    )
  end

  private

  def routing_configured?
    @user.routing_configured?
  end

  # Figures out where the book should go under the user's directory by
  # preserving the same sub-path structure that exists under the global base.
  # Example: canonical /audiobooks/Author/Title → user's /media/alice/Author/Title
  def build_user_destination(source)
    relative = Pathname(source).expand_path
      .relative_path_from(Pathname(global_base_path).expand_path)
    File.join(@user.preferred_output_path, relative.to_s)
  rescue ArgumentError
    # Relative path failed (e.g. source is on a different root).
    # Fall back to placing by basename so the file still lands somewhere useful.
    File.join(@user.preferred_output_path, File.basename(source))
  end

  # Mirrors PostProcessingJob#get_base_path — returns the configured system
  # output root for this book's content type.
  def global_base_path
    if @book.comicbook?
      SettingsService.get(:comicbook_output_path, default: "/comics")
    elsif @book.ebook?
      SettingsService.get(:ebook_output_path, default: "/ebooks")
    else
      SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    end
  end

  def perform_copy(source, destination)
    if File.directory?(source)
      FileUtils.mkdir_p(destination)
      Dir.each_child(source) do |entry|
        FileUtils.cp_r(File.join(source, entry), destination, preserve: true)
      end
    else
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination, preserve: true) unless File.exist?(destination)
    end
    Rails.logger.info "[UserLibraryRoutingService] Copied '#{File.basename(source)}' for user ##{@user.id}"
  end

  def perform_hardlink(source, destination)
    if File.directory?(source)
      hardlink_directory(source, destination)
    else
      FileUtils.mkdir_p(File.dirname(destination))
      File.link(source, destination) unless File.exist?(destination)
    end
    Rails.logger.info "[UserLibraryRoutingService] Hardlinked '#{File.basename(source)}' for user ##{@user.id}"
  rescue Errno::EXDEV
    # Source and destination are on different filesystems — hard links are
    # impossible across device boundaries, so fall back to a full copy.
    Rails.logger.warn(
      "[UserLibraryRoutingService] Cross-device hardlink not supported; " \
        "falling back to copy for user ##{@user.id}"
    )
    perform_copy(source, destination)
  end

  # Walks a directory tree, recreating the structure and hard-linking each
  # regular file. Directories themselves cannot be hard-linked (OS limitation).
  def hardlink_directory(source_dir, dest_dir)
    FileUtils.mkdir_p(dest_dir)
    Dir.each_child(source_dir) do |entry|
      source_entry = File.join(source_dir, entry)
      dest_entry = File.join(dest_dir, entry)
      if File.directory?(source_entry)
        hardlink_directory(source_entry, dest_entry)
      elsif File.file?(source_entry) && !File.exist?(dest_entry)
        File.link(source_entry, dest_entry)
      end
    end
  end

  # Persists the user's destination path so we know where their copy lives.
  # Uses find_or_create_by! so repeated calls are idempotent.
  def record_user_path(path)
    UserBookPath.find_or_create_by!(user: @user, book: @book) do |ubp|
      ubp.file_path = path
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn "[UserLibraryRoutingService] Could not record user book path: #{e.message}"
  end
end
