# frozen_string_literal: true

# Optional modes applied after a library import has already succeeded.
#
# A regular file with more than one link is skipped by the chmod itself. The
# link count comes from the same pinned descriptor that would be chmodded, so
# a shared download inode stays unchanged even when the caller does not know
# the names are linked. Copy, move, and hardlink-fallback copies own a separate
# inode and receive the file mode. Reference symlinks are not chmodded by
# callers, because that would follow the link onto the remote file. The
# configured library root is never chmodded.
class LibraryImportPermissions
  class << self
    def apply_file!(path, root:)
      mode = mode_for(:library_import_file_mode)
      return if mode.nil?

      FileCopyService.chmod_nofollow(path, mode, root: root, directory: false)
      nil
    rescue SystemCallError, FileCopyService::UnsafePathError, ArgumentError => error
      warn_failure(error)
      RemoteResult::Failed.new(error)
    end

    def apply_directory!(path, root:)
      mode = mode_for(:library_import_folder_mode)
      return if mode.nil?

      each_library_directory(path, root) do |directory|
        chmod_directory!(directory, root, mode)
      end
      nil
    rescue SystemCallError, FileCopyService::UnsafePathError, ArgumentError => error
      warn_failure(error)
      RemoteResult::Failed.new(error)
    end

    # Files and directories inside an already published library tree, plus
    # ancestor folders under the library root.
    def apply_tree!(path, root:)
      file_mode = mode_for(:library_import_file_mode)
      folder_mode = mode_for(:library_import_folder_mode)
      return if file_mode.nil? && folder_mode.nil?

      expanded = Pathname(path).expand_path
      root_path = Pathname(root).expand_path
      walk_tree(expanded, root_path, file_mode, folder_mode)
      apply_directory!(expanded.parent.to_s, root: root_path) if folder_mode
      nil
    rescue SystemCallError, FileCopyService::UnsafePathError, ArgumentError => error
      warn_failure(error)
      RemoteResult::Failed.new(error)
    end

    private

    def mode_for(key)
      text = SettingsService.get(key).to_s.strip
      return nil if text.empty? || !SettingsService.library_import_mode_acceptable?(key, text)

      Integer(text, 8)
    end

    def each_library_directory(path, root)
      root_path = Pathname(root).expand_path
      current = Pathname(path).expand_path
      return if current == root_path

      relative = current.relative_path_from(root_path)
      return if relative.to_s == ".." || relative.to_s.start_with?("..#{File::SEPARATOR}")

      directories = []
      while current != root_path
        directories << current
        current = current.parent
      end
      directories.reverse_each { |directory| yield directory }
    rescue ArgumentError => error
      warn_failure(error)
      RemoteResult::Failed.new(error)
    end

    def chmod_directory!(directory, root, mode)
      return if mode.nil?

      FileCopyService.chmod_nofollow(directory.to_s, mode, root: root, directory: true)
      nil
    rescue SystemCallError, FileCopyService::UnsafePathError, ArgumentError => error
      warn_failure(error)
      RemoteResult::Failed.new(error)
    end

    def walk_tree(path, root, file_mode, folder_mode)
      stat = File.lstat(path)
      if stat.symlink?
        nil
      elsif stat.directory?
        Dir.children(path).each do |name|
          next if name == "." || name == ".."

          walk_tree(path.join(name), root, file_mode, folder_mode)
        end
        chmod_directory!(path, root, folder_mode) if folder_mode && path != root
      elsif stat.file? && file_mode
        apply_file!(path.to_s, root: root)
      end
      nil
    rescue SystemCallError, FileCopyService::UnsafePathError, ArgumentError => error
      warn_failure(error)
      RemoteResult::Failed.new(error)
    end

    def warn_failure(error)
      Rails.logger.warn(
        "[LibraryImportPermissions] Could not apply the configured library import mode (#{error.class})"
      )
    end
  end
end
