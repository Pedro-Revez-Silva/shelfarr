# frozen_string_literal: true

require "json"
require "tempfile"
require "timeout"

class AudiobookProbeService
  MAX_OUTPUT_BYTES = 64.kilobytes
  MAX_PROBE_BYTES = 5.megabytes
  MAX_ANALYZE_MICROSECONDS = 5_000_000
  MAX_DURATION = 15.seconds
  MAX_ADDRESS_SPACE_BYTES = 512.megabytes
  SPAWN_RESOURCE_LIMITS = {
    rlimit_cpu: 10,
    rlimit_fsize: MAX_OUTPUT_BYTES,
    rlimit_core: 0
  }.tap do |limits|
    # Darwin exposes RLIMIT_AS but rejects attempts to set it with EINVAL.
    limits[:rlimit_as] = MAX_ADDRESS_SPACE_BYTES unless RUBY_PLATFORM.include?("darwin")
  end.freeze

  class << self
    attr_writer :probe

    def valid?(path, format_whitelist: nil)
      return @probe.call(path) if @probe

      probe_file(path, format_whitelist: format_whitelist)
    end

    def reset_probe!
      @probe = nil
    end

    private

    def probe_file(path, format_whitelist:)
      source = path if path.respond_to?(:fileno)
      return false if source && !source.stat.file?

      position = source&.pos
      # Pass the held file across exec. Descriptor-created staging files have
      # no pathname, and reopening a name could inspect replacement bytes.
      input_path = source ? "/dev/fd/3" : path.to_s
      input_mapping = source ? { 3 => source.fileno } : {}
      format_options = format_whitelist ? [ "-format_whitelist", format_whitelist.join(",") ] : []
      Tempfile.create([ "shelfarr-ffprobe-", ".json" ]) do |output|
        pid = Process.spawn(
          "ffprobe",
          "-v", "error",
          "-protocol_whitelist", "file,pipe",
          "-probesize", MAX_PROBE_BYTES.to_s,
          "-analyzeduration", MAX_ANALYZE_MICROSECONDS.to_s,
          "-select_streams", "a:0",
          "-show_entries", "stream=codec_type,duration:format=duration",
          "-of", "json",
          *format_options,
          "-i", input_path,
          in: File::NULL,
          out: output.path,
          err: File::NULL,
          pgroup: true,
          **SPAWN_RESOURCE_LIMITS,
          **input_mapping
        )
        status = wait_for_probe(pid)
        return false unless status&.success?

        output.rewind
        payload = output.read(MAX_OUTPUT_BYTES + 1)
        return false if payload.bytesize > MAX_OUTPUT_BYTES

        data = JSON.parse(payload)
        audio_stream = data.fetch("streams", []).find { |stream| stream["codec_type"] == "audio" }
        duration = audio_stream&.fetch("duration", nil).presence || data.dig("format", "duration")
        audio_stream.present? && duration.to_f.positive?
      end
    rescue SystemCallError, IOError, ArgumentError, JSON::ParserError, TypeError => error
      RemoteResult::Failed.new(error)
    ensure
      source.seek(position, IO::SEEK_SET) if source && !source.closed? && position
    end

    def wait_for_probe(pid)
      Timeout.timeout(MAX_DURATION) { Process.wait2(pid).last }
    rescue Timeout::Error => error
      terminate_probe(pid)
      RemoteResult::Failed.new(error)
    end

    def terminate_probe(pid)
      Process.kill("TERM", -pid)
      Timeout.timeout(1.second) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD => error
      RemoteResult::Failed.new(error)
    rescue Timeout::Error
      Process.kill("KILL", -pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD => error
      RemoteResult::Failed.new(error)
    end
  end
end
