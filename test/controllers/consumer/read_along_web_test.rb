# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/read_along_fixtures"

class Consumer::ReadAlongWebTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include ReadAlongFixtures

  setup do
    prepare_consumer_library
    Consumer::ReadAlong.forget_all
    write_read_along_epub(@epub_path)
    @asset = Consumer::LibraryAssets.new(@ebook).list.first
    sign_in_as(users(:one))
  end
  teardown { FileUtils.remove_entry(@root) if @root && File.exist?(@root) }

  def publication_json
    JSON.parse(css_select("script[data-consumer-reader-target=publication]").sole.text)
  end

  test "the reader page summarizes read-along and the manifest names real cues with same-session URLs" do
    get consumer_publication_path(@ebook)
    assert_response :success
    summary = publication_json.fetch("assets").sole.fetch("read_along")
    assert_equal "available", summary.fetch("status")
    assert_equal "media_overlay", summary.fetch("source")
    assert_equal "/read/#{@ebook.id}/assets/#{@asset.id}/read_along", summary.fetch("manifest_url")
    assert_equal({ "complete" => true, "text_sections" => 2, "aligned_sections" => 2, "cues" => 8, "audio_ms" => 14_400 }, summary.fetch("coverage"))
    assert_operator summary.fetch("text_bytes"), :<, 32.megabytes

    get summary.fetch("manifest_url")
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    manifest = response.parsed_body
    assert_equal 1, manifest.fetch("version")
    assert_equal summary.fetch("generation"), manifest.fetch("generation")
    assert_equal @asset.id, manifest.fetch("ebook_asset_id")
    assert_equal "/read/#{@ebook.id}/assets/#{@asset.id}/read_along/resources/", manifest.fetch("resources_url")
    audio = manifest.fetch("audio").sole
    assert_equal "/read/#{@ebook.id}/assets/#{@asset.id}/read_along/resources/OEBPS/audio/narration.mp3", audio.fetch("url")
    assert_equal [ 0, "c0", 0, 0, 1800 ], manifest.fetch("cues").first
  end

  test "resources are exact archive entries with ranges, attachment, sandbox and no unlisted paths" do
    base = "/read/#{@ebook.id}/assets/#{@asset.id}/read_along/resources"
    get "#{base}/OEBPS/chapter1.xhtml"
    assert_response :success
    assert_equal "application/xhtml+xml", response.media_type
    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
    assert_equal ConsumerReadAlongResponse::RESOURCE_POLICY, response.headers["Content-Security-Policy"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_includes response.body, %(<p id="c3">)

    get "#{base}/OEBPS/audio/narration.mp3", headers: { "Range" => "bytes=1000-1999" }
    assert_response :partial_content
    assert_equal "audio/mpeg", response.media_type
    assert_equal "bytes 1000-1999/#{tone_bytes.bytesize}", response.headers["Content-Range"]
    assert_equal tone_bytes.byteslice(1000, 1000), response.body.b
    etag = response.headers["ETag"]
    get "#{base}/OEBPS/audio/narration.mp3", headers: { "If-None-Match" => etag }
    assert_response :not_modified
    get "#{base}/OEBPS/audio/narration.mp3", headers: { "Range" => "bytes=999999-" }
    assert_response :range_not_satisfiable

    [ "mimetype", "OEBPS/chapter1.smil", "OEBPS/../mimetype", "OEBPS/missing.xhtml", "%2e%2e/%2e%2e/etc/passwd" ].each do |path|
      get "#{base}/#{path}"
      assert_includes [ 404, 410 ], response.status, path
    end
  end

  test "deflated narration audio is served by range within its announced size" do
    write_read_along_epub(@epub_path, audio_stored: false)
    Consumer::ReadAlong.forget_all
    asset = Consumer::LibraryAssets.new(@ebook).list.first
    get "/read/#{@ebook.id}/assets/#{asset.id}/read_along/resources/OEBPS/audio/narration.mp3", headers: { "Range" => "bytes=50000-" }
    assert_response :partial_content
    assert_equal tone_bytes.byteslice(50_000..), response.body.b
  end

  test "an old generation's manifest and resources are gone, not silently re-pointed" do
    old = @asset.id
    write_read_along_epub(@epub_path, title: "An updated edition")
    get "/read/#{@ebook.id}/assets/#{old}/read_along"
    assert_response :gone
    get "/read/#{@ebook.id}/assets/#{old}/read_along/resources/OEBPS/chapter1.xhtml"
    assert_response :gone
  end

  test "unaligned, invalid and stale editions explain themselves and keep normal reading" do
    write_read_along_epub(@epub_path, cues: default_read_along_cues.each_with_index.map { |cue, index| index == 1 ? cue.merge(clip_begin: "0:00:01.000") : cue })
    Consumer::ReadAlong.forget_all
    asset = Consumer::LibraryAssets.new(@ebook).list.first
    get "/read/#{@ebook.id}/assets/#{asset.id}/read_along"
    assert_response :unprocessable_entity
    assert_equal "read_along_invalid", response.parsed_body.fetch("error")
    get consumer_publication_path(@ebook)
    summary = publication_json.fetch("assets").sole.fetch("read_along")
    assert_equal "invalid", summary.fetch("status")
    assert_not summary.key?("manifest_url")
    get publication_json.fetch("assets").sole.fetch("content_url")
    assert_response :success

    write_read_along_epub(@epub_path, overlay: false)
    asset = Consumer::LibraryAssets.new(@ebook).list.first
    get "/read/#{@ebook.id}/assets/#{asset.id}/read_along"
    assert_response :not_found
    assert_equal "read_along_unaligned", response.parsed_body.fetch("error")
  end

  test "imported alignments serve only their bound audiobook files under the ebook path" do
    write_read_along_epub(@epub_path, overlay: false)
    FileUtils.cp(TONES, @audio_path)
    Consumer::ReadAlong::Import.new(ebook: @ebook, audiobook: @audiobook).call(read_along_document(epub_path: @epub_path, audio_path: @audio_path))
    asset = Consumer::LibraryAssets.new(@ebook).list.first
    audio_asset = Consumer::LibraryAssets.new(@audiobook).list.first
    get consumer_publication_path(@ebook)
    publication = publication_json
    assert_equal "imported", publication.fetch("assets").sole.dig("read_along", "source")
    assert_equal({ "id" => @audiobook.id.to_s, "title" => @audiobook.title, "progress_url" => "/read/#{@audiobook.id}/progress", "progress" => nil },
      publication.fetch("read_along_audiobook"))
    get "/read/#{@ebook.id}/assets/#{asset.id}/read_along"
    track = response.parsed_body.fetch("audio").sole
    assert_equal "publication_asset", track.fetch("kind")
    assert_equal "/read/#{@ebook.id}/assets/#{asset.id}/read_along/audio/#{audio_asset.id}", track.fetch("url")
    get track.fetch("url"), headers: { "Range" => "bytes=0-99" }
    assert_response :partial_content
    assert_equal tone_bytes.byteslice(0, 100), response.body.b

    other = Book.create!(title: "Unrelated", author: "Someone", book_type: :audiobook, file_path: File.join(@root, "other.mp3"))
    File.binwrite(other.file_path, "other audio")
    get "/read/#{@ebook.id}/assets/#{asset.id}/read_along/audio/#{Consumer::LibraryAssets.new(other).list.first.id}"
    assert_response :gone

    File.binwrite(@audio_path, tone_bytes.reverse)
    Consumer::ReadAlong.forget_all
    get track.fetch("url")
    assert_response :gone
    get "/read/#{@ebook.id}/assets/#{asset.id}/read_along"
    assert_response :conflict
    assert_equal "stale", response.parsed_body.fetch("status")
  end

  test "a deployment subpath prefixes every read-along URL" do
    get consumer_publication_path(@ebook), env: { "SCRIPT_NAME" => "/shelf" }
    summary = publication_json.fetch("assets").sole.fetch("read_along")
    assert_equal "/shelf/read/#{@ebook.id}/assets/#{@asset.id}/read_along", summary.fetch("manifest_url")
    get "/read/#{@ebook.id}/assets/#{@asset.id}/read_along", env: { "SCRIPT_NAME" => "/shelf" }
    manifest = response.parsed_body
    assert manifest.fetch("resources").all? { |resource| resource.fetch("url").start_with?("/shelf/read/") }
    assert manifest.fetch("audio").sole.fetch("url").start_with?("/shelf/read/")
  end

  test "a read-along place records where the narration was heard, and malformed ones are refused" do
    generation = Consumer::ReadAlong.for(@ebook, @asset).generation
    place = { href: "OEBPS/chapter1.xhtml", type: "application/xhtml+xml",
      locations: { fragments: [ "c3" ], progression: 0.6, totalProgression: 0.3, readAlong: { generation: generation, audio: 0, offset_ms: 6400 } } }
    headers = { "X-Shelfarr-Account" => users(:one).id.to_s }
    put consumer_progress_path(@ebook), params: { asset_id: @asset.id, expected_version: 0, client_mutation_id: SecureRandom.uuid,
      observed_at: Time.current.utc.iso8601(3), locator: place }, headers: headers, as: :json
    assert_response :success
    stored = users(:one).consumer_progresses.find_by!(book: @ebook)
    assert_equal({ "generation" => generation, "audio" => 0, "offset_ms" => 6400 }, stored.locator.dig("locations", "readAlong"))
    [ { generation: "x", audio: 0, offset_ms: 1 }, { generation: generation, audio: -1, offset_ms: 1 },
      { generation: generation, audio: 0, offset_ms: 1.5 }, { generation: generation, audio: 0, offset_ms: 1, guessed: true } ].each do |bad|
      put consumer_progress_path(@ebook), params: { asset_id: @asset.id, expected_version: 1, client_mutation_id: SecureRandom.uuid,
        locator: place.deep_merge(locations: { readAlong: bad }) }, headers: headers, as: :json
      assert_response :unprocessable_entity, bad.inspect
    end
  end
end
