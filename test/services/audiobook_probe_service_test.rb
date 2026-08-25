# frozen_string_literal: true

require "test_helper"

class AudiobookProbeServiceTest < ActiveSupport::TestCase
  teardown do
    AudiobookProbeService.reset_probe!
  end

  test "accepts a bounded probe result with an audio stream and positive duration" do
    with_fake_ffprobe('{"streams":[{"codec_type":"audio","duration":"12.5"}],"format":{"duration":"12.5"}}') do
      assert AudiobookProbeService.valid?("/tmp/book.mp3")
    end
  end

  test "rejects probe results without a positive-duration audio stream" do
    with_fake_ffprobe('{"streams":[{"codec_type":"video"}],"format":{"duration":"0"}}') do
      assert_not AudiobookProbeService.valid?("/tmp/not-audiobook.mp3")
    end
  end

  test "fails closed when ffprobe is unavailable" do
    with_path(Dir.mktmpdir) do
      assert_not AudiobookProbeService.valid?("/tmp/book.mp3")
    end
  end

  test "works with real ffprobe on a valid audio file" do
    skip "ffprobe not available" unless system("ffprobe", "-version", out: File::NULL, err: File::NULL)
    skip "ffmpeg not available" unless system("ffmpeg", "-version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |dir|
      audio_file = File.join(dir, "test.mp3")
      generated = system(
        "ffmpeg", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
        "-c:a", "libmp3lame", "-b:a", "64k", audio_file, "-y",
        in: File::NULL, out: File::NULL, err: File::NULL
      )

      assert generated, "Test audio file should be created"
      assert AudiobookProbeService.valid?(audio_file),
             "AudiobookProbeService should validate a real audio file with the actual ffprobe binary"
    end
  end

  private

  def with_fake_ffprobe(payload)
    Dir.mktmpdir do |directory|
      executable = File.join(directory, "ffprobe")
      File.write(executable, "#!/bin/sh\nprintf '%s' '#{payload}'\n")
      File.chmod(0o700, executable)
      with_path(directory) { yield }
    end
  end

  def with_path(path)
    previous = ENV.fetch("PATH", nil)
    ENV["PATH"] = path
    yield
  ensure
    ENV["PATH"] = previous
  end
end
