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

  class << self
    attr_writer :probe

    def valid?(path)
      return @probe.call(path) if @probe

      probe_file(path)
    end

    def reset_probe!
      @probe = nil
    end

    private

    def probe_file(path)
      Tempfile.create([ "shelfarr-ffprobe-", ".json" ]) do |output|
        pid = Process.spawn(
          "ffprobe",
          "-nostdin",
          "-v", "error",
          "-protocol_whitelist", "file,pipe",
          "-probesize", MAX_PROBE_BYTES.to_s,
          "-analyzeduration", MAX_ANALYZE_MICROSECONDS.to_s,
          "-select_streams", "a:0",
          "-show_entries", "stream=codec_type,duration:format=duration",
          "-of", "json",
          "-i", path.to_s,
          out: output.path,
          err: File::NULL,
          pgroup: true,
          rlimit_cpu: 10,
          rlimit_as: MAX_ADDRESS_SPACE_BYTES,
          rlimit_fsize: MAX_OUTPUT_BYTES,
          rlimit_core: 0
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
    rescue SystemCallError, ArgumentError, JSON::ParserError, TypeError
      false
    end

    def wait_for_probe(pid)
      Timeout.timeout(MAX_DURATION) { Process.wait2(pid).last }
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
