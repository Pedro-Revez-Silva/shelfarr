# frozen_string_literal: true

require "fiddle"

# Descriptor-relative libc filesystem operations used by publication services.
module FilesystemSyscalls
  LINUX_RENAME_NOREPLACE = 0x1
  DARWIN_RENAME_EXCL = 0x4

  class << self
    def openat(directory_fd, basename, flags:, mode: 0)
      Fiddle.last_error = 0
      descriptor = if (flags & File::CREAT).positive?
        # openat is variadic when O_CREAT is present. On arm64 Darwin, treating
        # mode_t as a fixed fourth argument silently creates mode-000 files.
        native_function(
          :openat_create,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VARIADIC ],
          symbol: :openat
        ).call(directory_fd, path_pointer(basename), flags, Fiddle::TYPE_INT, mode)
      else
        native_function(
          :openat,
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ]
        ).call(directory_fd, path_pointer(basename), flags)
      end
      return descriptor unless descriptor == -1

      raise SystemCallError.new("openat", Fiddle.last_error)
    end

    def mkdirat(directory_fd, basename, mode)
      call_zero(
        :mkdirat,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ],
        directory_fd,
        path_pointer(basename),
        mode
      )
    end

    def linkat(source_fd, source_basename, destination_fd, destination_basename)
      call_zero(
        :linkat,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ],
        source_fd,
        path_pointer(source_basename),
        destination_fd,
        path_pointer(destination_basename),
        0
      )
    end

    def symlinkat(target, directory_fd, basename)
      call_zero(
        :symlinkat,
        [ Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP ],
        path_pointer(target),
        directory_fd,
        path_pointer(basename)
      )
    end

    def readlinkat(directory_fd, basename)
      buffer_size = 4096
      buffer = Fiddle::Pointer.malloc(buffer_size)
      Fiddle.last_error = 0
      length = native_function(
        :readlinkat,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T ]
      ).call(directory_fd, path_pointer(basename), buffer, buffer_size)
      raise SystemCallError.new("readlinkat", Fiddle.last_error) if length == -1

      buffer.to_s(length).force_encoding(Encoding::UTF_8)
    end

    def unlinkat(directory_fd, basename, flags = 0)
      call_zero(
        :unlinkat,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT ],
        directory_fd,
        path_pointer(basename),
        flags
      )
    end

    def fchmod(descriptor, mode)
      call_zero(:fchmod, [ Fiddle::TYPE_INT, Fiddle::TYPE_INT ], descriptor, mode)
    end

    def ftruncate(descriptor, length)
      call_zero(:ftruncate, [ Fiddle::TYPE_INT, Fiddle::TYPE_LONG ], descriptor, length)
    end

    def futimes_now(descriptor)
      call_zero(:futimes, [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP ], descriptor, nil)
    end

    def renameat(source_fd, source_basename, destination_fd, destination_basename)
      call_zero(
        :renameat,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP ],
        source_fd,
        path_pointer(source_basename),
        destination_fd,
        path_pointer(destination_basename)
      )
    end

    def rename_noreplace(source_fd, source_basename, destination_fd, destination_basename)
      function, flag = if RUBY_PLATFORM.include?("darwin")
        [ :renameatx_np, DARWIN_RENAME_EXCL ]
      elsif RUBY_PLATFORM.include?("linux")
        [ :renameat2, LINUX_RENAME_NOREPLACE ]
      else
        return false
      end

      call_zero(
        function,
        [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT ],
        source_fd,
        path_pointer(source_basename),
        destination_fd,
        path_pointer(destination_basename),
        flag
      )
      true
    rescue Fiddle::DLError, Errno::ENOSYS, Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOTSUP
      false
    end

    private

    def call_zero(name, arguments, *values)
      Fiddle.last_error = 0
      result = native_function(name, arguments).call(*values)
      return result if result.zero?

      raise SystemCallError.new(name.to_s, Fiddle.last_error)
    end

    def native_function(name, arguments, symbol: name)
      @native_functions ||= {}
      @native_functions[[ name, arguments ]] ||= Fiddle::Function.new(
        Fiddle::Handle::DEFAULT[symbol.to_s],
        arguments,
        Fiddle::TYPE_INT
      )
    end

    def path_pointer(path)
      Fiddle::Pointer[path.to_s.b + "\0"]
    end
  end
end
