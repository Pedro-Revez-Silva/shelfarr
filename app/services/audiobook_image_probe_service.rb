# frozen_string_literal: true

require "json"
require "rbconfig"
require "tempfile"
require "timeout"

class AudiobookImageProbeService
  MAX_OUTPUT_BYTES = 16.kilobytes
  MAX_FILE_BYTES = 20.megabytes
  MAX_DIMENSION = 12_000
  MAX_PIXELS = 40_000_000
  MAX_DURATION = 10.seconds
  MAX_ADDRESS_SPACE_BYTES = 768.megabytes
  SUPPORTED_FORMATS = %w[jpeg png webp].freeze
  PROBE_SCRIPT = <<~'RUBY'.freeze
    Vips.concurrency_set(1)
    Vips.cache_set_max(0)
    Vips.cache_set_max_mem(32 * 1024 * 1024)
    input_path = ARGV.fetch(0)
    format = ARGV.fetch(1)
    image = case format
    when "jpeg" then Vips::Image.jpegload(input_path, access: :sequential, fail_on: :error)
    when "png" then Vips::Image.pngload(input_path, access: :sequential, fail_on: :error)
    when "webp" then Vips::Image.webpload(input_path, access: :sequential, fail_on: :error)
    else abort "unsupported image format"
    end
    pages = image.get_typeof("n-pages").zero? ? 1 : image.get("n-pages")
    abort "animated images are not supported" unless pages == 1
    encoded = case format
    when "jpeg" then image.jpegsave_buffer(Q: 90, strip: true)
    when "png" then image.pngsave_buffer(strip: true)
    when "webp" then image.webpsave_buffer(Q: 90, strip: true)
    end
    output = IO.new(4, "wb", autoclose: false)
    output.write(encoded)
    output.flush
    puts JSON.generate(
      width: image.width,
      height: image.height,
      pages: pages,
      loader: image.get("vips-loader")
    )
  RUBY

  class << self
    def sanitize!(path, expected_format:, max_duration: MAX_DURATION)
      return false unless SUPPORTED_FORMATS.include?(expected_format)
      return false unless max_duration.to_f.positive?

      with_regular_file(path) do |file|
        return false unless file.stat.size.between?(1, MAX_FILE_BYTES)

        probe_and_replace(file, path, expected_format, [ max_duration, MAX_DURATION ].min)
      end
    rescue SystemCallError, ArgumentError
      false
    end

    private

    def with_regular_file(path_or_io)
      if path_or_io.respond_to?(:stat) && path_or_io.respond_to?(:read)
        return false unless path_or_io.stat.file?

        return yield path_or_io
      end

      File.open(path_or_io, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        return false unless file.stat.file?

        yield file
      end
    end

    def probe_and_replace(file, path, expected_format, max_duration)
      Tempfile.create([ "shelfarr-image-probe-", ".json" ]) do |metadata_output|
        Tempfile.create([ ".shelfarr-image-", ".#{expected_format}" ], File.dirname(path)) do |image_output|
          file.rewind
          image_output.truncate(0)
          image_output.rewind
          pid = Process.spawn(
            RbConfig.ruby,
            "-rbundler/setup",
            "-rvips",
            "-rjson",
            "-e", PROBE_SCRIPT,
            descriptor_path(3),
            expected_format,
            3 => file,
            4 => image_output,
            out: metadata_output.path,
            err: File::NULL,
            pgroup: true,
            rlimit_cpu: 5,
            rlimit_as: MAX_ADDRESS_SPACE_BYTES,
            rlimit_fsize: MAX_FILE_BYTES,
            rlimit_core: 0
          )
          status = wait_for_probe(pid, max_duration)
          return false unless status&.success?

          metadata_output.rewind
          payload = metadata_output.read(MAX_OUTPUT_BYTES + 1)
          return false if payload.bytesize > MAX_OUTPUT_BYTES

          image_output.flush
          return false unless image_output.size.between?(1, MAX_FILE_BYTES)
          return false unless valid_metadata?(JSON.parse(payload), expected_format)
          return false unless File.identical?(file, path)

          File.rename(image_output.path, path)
          true
        end
      end
    rescue JSON::ParserError, TypeError
      false
    end

    def valid_metadata?(metadata, expected_format)
      width = Integer(metadata.fetch("width"))
      height = Integer(metadata.fetch("height"))
      pages = Integer(metadata.fetch("pages"))
      loader = metadata.fetch("loader").to_s

      pages == 1 &&
        loader.start_with?("#{expected_format}load") &&
        width.between?(1, MAX_DIMENSION) &&
        height.between?(1, MAX_DIMENSION) &&
        width * height <= MAX_PIXELS
    rescue KeyError, ArgumentError, TypeError
      false
    end

    def descriptor_path(file_descriptor)
      linux_path = "/proc/self/fd/#{file_descriptor}"
      return linux_path if File.directory?("/proc/self/fd")

      "/dev/fd/#{file_descriptor}"
    end

    def wait_for_probe(pid, max_duration)
      Timeout.timeout(max_duration) { Process.wait2(pid).last }
    rescue Timeout::Error
      terminate_probe(pid)
      nil
    end

    def terminate_probe(pid)
      Process.kill("TERM", -pid)
      Timeout.timeout(1.second) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      Process.kill("KILL", -pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
