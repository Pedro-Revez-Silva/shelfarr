# frozen_string_literal: true

require "test_helper"
require "base64"

class AudiobookImageProbeServiceTest < ActiveSupport::TestCase
  test "accepts a fully decodable static image matching the expected format" do
    Tempfile.create([ "cover", ".png" ]) do |file|
      file.binmode
      file.write(valid_png_image)
      file.flush

      assert AudiobookImageProbeService.sanitize!(file.path, expected_format: "png")
    end
  end

  test "rejects truncated images and format mismatches" do
    Tempfile.create([ "cover", ".png" ]) do |file|
      file.binmode
      file.write(valid_png_image.byteslice(0, 40))
      file.flush

      assert_not AudiobookImageProbeService.sanitize!(file.path, expected_format: "png")

      file.rewind
      file.truncate(0)
      file.write(valid_png_image)
      file.flush
      assert_not AudiobookImageProbeService.sanitize!(file.path, expected_format: "jpeg")
    end
  end

  test "rejects unsupported expected formats" do
    assert_not AudiobookImageProbeService.sanitize!("/tmp/cover.gif", expected_format: "gif")
  end

  test "removes payloads appended to otherwise valid images" do
    Tempfile.create([ "cover", ".png" ]) do |file|
      file.binmode
      file.write(valid_png_image + "<script>payload</script>")
      file.flush

      assert AudiobookImageProbeService.sanitize!(file.path, expected_format: "png")
      assert_not_includes File.binread(file.path), "<script>payload</script>"
    end
  end

  test "sanitizes ordinary JPEG PNG and WebP covers" do
    require "vips"

    Dir.mktmpdir do |directory|
      image = Vips::Image.black(1_024, 768, bands: 3).new_from_image([ 32, 96, 160 ])
      { "jpeg" => "jpg", "png" => "png", "webp" => "webp" }.each do |format, extension|
        path = File.join(directory, "cover.#{extension}")
        image.write_to_file(path)

        assert AudiobookImageProbeService.sanitize!(path, expected_format: format), format
        assert File.size(path).between?(1, AudiobookImageProbeService::MAX_FILE_BYTES)
      end
    end
  end

  private

  def valid_png_image
    Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )
  end
end
