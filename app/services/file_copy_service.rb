# frozen_string_literal: true

# NFS-safe file copy operations.
#
# Ruby's IO.copy_stream (used by FileUtils.cp/cp_r) attempts the
# copy_file_range syscall for efficient file-to-file copies. This syscall
# fails with Errno::EACCES on NFS mounts even when the user has full
# read/write permissions. This service catches that specific failure and
# falls back to a buffered read/write copy.
#
# See: https://github.com/Pedro-Revez-Silva/shelfarr/issues/131
class FileCopyService
  BUFFER_SIZE = 1024 * 1024 # 1 MB

  class << self
    def cp(src, dest)
      FileUtils.cp(src, dest)
    rescue Errno::EACCES => e
      raise unless copy_file_range_error?(e)

      Rails.logger.info "[FileCopyService] copy_file_range failed on NFS, falling back to buffered copy for #{File.basename(src)}"
      buffered_copy(src, dest)
    end

    def cp_r(src, dest)
      FileUtils.cp_r(src, dest)
    rescue Errno::EACCES => e
      raise unless copy_file_range_error?(e)

      Rails.logger.info "[FileCopyService] copy_file_range failed on NFS, falling back to buffered recursive copy"
      recursive_buffered_copy(src, dest)
    end

    def mv(src, dest)
      FileUtils.mv(src, dest)
    rescue Errno::EACCES => e
      raise unless copy_file_range_error?(e)

      Rails.logger.info "[FileCopyService] copy_file_range failed on NFS, falling back to buffered move for #{File.basename(src)}"
      move_via_copy(src, dest)
    end

    private

    def copy_file_range_error?(error)
      error.message.include?("copy_file_range")
    end

    def move_via_copy(src, dest)
      cp(src, dest)
      remove_source_safely(src, dest)
    end

    def remove_source_safely(src, dest)
      if File.directory?(src)
        FileUtils.rm_rf(src)
      else
        FileUtils.rm_f(src)
      end
    rescue => e
      if source_move_verified?(src, dest)
        Rails.logger.warn "[FileCopyService] Source removal failed after successful copy (non-fatal): #{e.message}"
      else
        raise
      end
    end

    def source_move_verified?(src, dest)
      dest_path = resolved_destination_path(src, dest)
      return false unless dest_path && File.exist?(dest_path)

      if File.directory?(src)
        File.directory?(dest_path)
      else
        File.file?(dest_path) && File.size(dest_path) == File.size(src)
      end
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def resolved_destination_path(src, dest)
      File.directory?(dest) ? File.join(dest, File.basename(src)) : dest
    end

    def buffered_copy(src, dest)
      dest = File.join(dest, File.basename(src)) if File.directory?(dest)

      File.open(src, "rb") do |source|
        File.open(dest, "wb") do |target|
          buf = +""
          target.write(buf) while source.read(BUFFER_SIZE, buf)
        end
      end

      stat = File.stat(src)
      FileUtils.chmod(stat.mode, dest)
      File.utime(stat.atime, stat.mtime, dest)
    end

    def recursive_buffered_copy(src, dest)
      if File.directory?(src)
        dest_dir = File.directory?(dest) ? File.join(dest, File.basename(src)) : dest
        FileUtils.mkdir_p(dest_dir)
        FileUtils.chmod(File.stat(src).mode, dest_dir)

        (Dir.entries(src) - %w[. ..]).each do |entry|
          recursive_buffered_copy(File.join(src, entry), dest_dir)
        end
      else
        buffered_copy(src, dest)
      end
    end
  end
end
