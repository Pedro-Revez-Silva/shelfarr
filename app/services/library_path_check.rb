# frozen_string_literal: true

class LibraryPathCheck
  QBITTORRENT_MISMATCH = "That path is not inside /downloads or does not exist."
  ABS_MISSING_FOLDER = "ABS did not report a folder."

  class << self
    def qbittorrent_message(save_path:, category_save_path:, category:, local_path:, remote_path:)
      effective = effective_save_path(save_path, category_save_path, category)
      return if effective.blank?

      mapped = remap(effective, remote_path, local_path) || normalize_path(effective)
      return if mapped.blank?
      return if aligned?(mapped, local_path, save_path, category_save_path, category, remote_path)

      "qBittorrent save path #{effective} maps to #{mapped}. #{QBITTORRENT_MISMATCH}"
    end

    def audiobookshelf_messages(libraries:, audiobook_library_id:, ebook_library_id:, audiobook_output_path:, ebook_output_path:)
      [
        folder_message(libraries, audiobook_library_id, audiobook_output_path),
        folder_message(libraries, ebook_library_id, ebook_output_path)
      ].compact.uniq
    end

    private

    def effective_save_path(save_path, category_save_path, category)
      return category_save_path if category_save_path.present?
      return if save_path.blank?
      return File.join(save_path.to_s, category.to_s) if category.present?

      save_path
    end

    # qBittorrent creates category/save_path lazily, so a missing child of an
    # existing in-container save path is not a mount mismatch.
    def aligned?(mapped, local_path, save_path, category_save_path, category, remote_path)
      return false unless inside?(mapped, local_path)
      return true if directory_exists?(mapped)
      return false if category_save_path.present? || category.blank? || save_path.blank?

      parent = remap(save_path, remote_path, local_path) || normalize_path(save_path)
      inside?(parent, local_path) && directory_exists?(parent)
    end

    def folder_message(libraries, library_id, output_path)
      return if library_id.blank? || output_path.blank?

      library = Array(libraries).find { |item| item.id.to_s == library_id.to_s }
      folders = library&.folder_paths.to_a.filter_map { |path| path.to_s.presence }
      return ABS_MISSING_FOLDER if folders.empty?
      return if folders.any? { |folder| same_path?(folder, output_path) }

      "ABS folder is #{folders.first}; Shelfarr imports to #{output_path}. " \
        "Mount the same directory at the same path in both containers, or change the output path."
    end

    def same_path?(left, right)
      normalize_path(left) == normalize_path(right)
    end

    def inside?(path, root)
      candidate = normalize_path(path)
      base = normalize_path(root)
      return false if candidate.blank? || base.blank?

      candidate == base || candidate.start_with?("#{base}/")
    end

    def remap(path, remote_path, local_path)
      candidate = normalize_path(path)
      remote = normalize_path(remote_path)
      local = normalize_path(local_path)
      return if candidate.blank? || remote.blank? || local.blank?
      return unless candidate == remote || candidate.start_with?("#{remote}/")

      suffix = candidate.delete_prefix(remote).sub(%r{\A/+}, "")
      suffix.present? ? normalize_path(File.join(local, suffix)) : local
    end

    def normalize_path(path)
      value = path.to_s.tr("\\", "/").strip
      return if value.blank?

      value.sub(%r{/+\z}, "").presence || "/"
    end

    def directory_exists?(path)
      Dir.exist?(path.to_s)
    rescue SystemCallError
      false
    end
  end
end
