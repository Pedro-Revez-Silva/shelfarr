# frozen_string_literal: true

module SyntheticLibraryModesTestHelper
  # Ruby's Fcntl module does not expose Darwin's F_GETPATH.
  DARWIN_F_GETPATH = 50
  DARWIN_PATH_BUFFER_SIZE = 1024

  def with_synthetic_library_modes(
    root:,
    file_mode:,
    directory_mode:,
    fchmod_error: nil,
    &operation
  )
    root = File.realpath(root)
    real_fchmod = FileCopyService.method(:native_fchmod)
    synthetic_fchmod = lambda do |descriptor, requested_mode|
      descriptor_path = synthetic_mode_descriptor_path(descriptor)
      unless descriptor_path == root || descriptor_path.start_with?("#{root}/")
        next real_fchmod.call(descriptor, requested_mode)
      end

      handle = File.for_fd(descriptor, "rb", autoclose: false)
      handle.chmod(handle.stat.directory? ? directory_mode : file_mode)
      raise fchmod_error if fchmod_error
    end

    FileCopyService.stub(:native_fchmod, synthetic_fchmod, &operation)
  end

  private

  def synthetic_mode_descriptor_path(descriptor)
    if File.directory?("/proc/self/fd")
      return File.readlink("/proc/self/fd/#{descriptor}")
    end

    if RUBY_PLATFORM.include?("darwin")
      handle = File.for_fd(descriptor, "rb", autoclose: false)
      buffer = "\0" * DARWIN_PATH_BUFFER_SIZE
      handle.fcntl(DARWIN_F_GETPATH, buffer)
      return buffer.split("\0", 2).first
    end

    raise "Cannot resolve file descriptor paths on #{RUBY_PLATFORM}"
  end
end
