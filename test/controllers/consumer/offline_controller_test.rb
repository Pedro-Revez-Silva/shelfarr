# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"

class Consumer::OfflineControllerTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper

  setup { prepare_consumer_library }
  teardown { FileUtils.remove_entry(@root) }

  test "the worker script is static, account-free and names exactly what it precaches" do
    get consumer_offline_worker_path
    assert_response :success
    assert_equal "text/javascript", response.media_type
    assert_equal "no-cache", response.headers["Cache-Control"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    config = worker_config
    assert_equal consumer_offline_shell_path, config.fetch("shell")
    assert_match(/\A\h{24}\z/, config.fetch("version"))
    assets = config.fetch("assets")
    assert assets.any? { |path| path.match?(%r{\A/assets/consumer-\h+\.css\z}) }, assets.inspect
    assert assets.any? { |path| path.match?(%r{\A/assets/Newsreader-Regular-\h+\.ttf\z}) }, assets.inspect
    assert assets.any? { |path| path.include?("consumer_reader_engine") }
    assert assets.any? { |path| path.include?("consumer_offline-") }
    # The PDF renderer opens offline: its engine, worker, fonts, CMaps and decoders are precached.
    assert assets.any? { |path| path.include?("consumer_pdf_engine-") }
    assert assets.any? { |path| path.include?("consumer_page_reader-") }
    assert assets.any? { |path| path.match?(%r{\A/assets/pdfjs/pdf\.worker-\h+\.js\z}) }, assets.inspect
    assert assets.any? { |path| path.match?(%r{\A/assets/pdfjs/standard_fonts/LiberationSans-Regular-\h+\.ttf\z}) }
    assert assets.any? { |path| path.match?(%r{\A/assets/pdfjs/cmaps/UniJIS-UCS2-H-\h+\.bcmap\z}) }
    assert assets.any? { |path| path.match?(%r{\A/assets/pdfjs/wasm/openjpeg-\h+\.wasm\z}) }
    assert_not assets.any? { |path| path.include?("quickjs") || path.include?("LICENSE") }
    assert assets.all? { |path| path.start_with?("/assets/") }, "only digested assets are precached"
    assert_includes response.body, "self.addEventListener(\"fetch\""

    sign_in_as(users(:one))
    get consumer_offline_worker_path
    assert_equal config, worker_config, "the worker is identical for every account"
  end

  test "the worker and shell follow the deployment subpath" do
    get "/read-offline-worker.js", env: { "SCRIPT_NAME" => "/shelf" }
    assert_response :success
    assert_equal "/shelf/read/offline", worker_config.fetch("shell")
    get "/read/offline", env: { "SCRIPT_NAME" => "/shelf" }
    assert_select "[data-controller=consumer-offline-shell][data-consumer-offline-shell-base-value='/shelf']"
    assert_select "[data-consumer-offline-shell-account-url-value='/shelf/read/offline/account']"
    assert_select "a.consumer-wordmark[href='/shelf/read']"
  end

  test "the offline shell carries no session token, account or book data" do
    get consumer_offline_shell_path
    assert_response :success
    signed_out = response.body
    assert_equal "no-cache", response.headers["Cache-Control"]
    assert_select "meta[name=csrf-token][content='']"
    assert_select "meta[name=turbo-visit-control][content=reload]"
    assert_select "template[data-consumer-offline-shell-target=ebook] [data-controller=consumer-reader]"
    assert_select "template[data-consumer-offline-shell-target=audio] audio"
    assert_select "form", count: 0
    assert_not_includes signed_out, @ebook.title

    sign_in_as(users(:one))
    get consumer_offline_shell_path
    assert_equal signed_out, response.body, "the shell must be the same for every account"
    assert_nil response.cookies["session_id"].presence
  end

  test "account confirmation is personal, never cached and answers JSON when signed out" do
    get consumer_offline_account_path
    assert_response :unauthorized
    assert_equal({ "error" => "signed_out" }, response.parsed_body)

    sign_in_as(users(:one))
    get consumer_offline_account_path
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal users(:one).id.to_s, body.fetch("account")
    assert body.fetch("csrf_token").present?
    assert_equal 30, body.fetch("session_max_age_days")
  end

  test "downloaded publications refresh with web media URLs, saved places and removed titles" do
    sign_in_as(users(:one))
    asset = consumer_asset(@audiobook)
    users(:one).consumer_progresses.create!(book: @audiobook, asset_id: asset.id, position_seconds: 12, version: 3,
      client_mutation_id: SecureRandom.uuid, observed_at: 1.minute.ago)
    get consumer_offline_publications_path(ids: "#{@ebook.id},#{@audiobook.id},999999")
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal users(:one).id.to_s, body.fetch("account")
    assert_equal [ "999999" ], body.fetch("missing")
    audio = body.fetch("publications").find { |publication| publication["id"] == @audiobook.id.to_s }
    assert_equal consumer_asset_path(@audiobook, asset.id), audio.dig("assets", 0, "content_url")
    assert_equal consumer_progress_path(@audiobook), audio.fetch("progress_url")
    assert_equal({ "account" => users(:one).id.to_s, "base" => "" }, audio.fetch("progress_scope"))
    assert_equal 3, audio.dig("progress", "version")
    assert_equal true, audio.dig("offline", "supported")
    assert_not_includes response.body, @root
  end

  test "publication refreshes reject malformed or unbounded lists and signed-out callers" do
    get consumer_offline_publications_path(ids: @ebook.id.to_s)
    assert_response :unauthorized
    sign_in_as(users(:one))
    [ "", "abc", "1,,2", "0", (1..51).to_a.join(",") ].each do |ids|
      get consumer_offline_publications_path(ids: ids)
      assert_response :unprocessable_entity, ids
    end
    get consumer_offline_publications_path, params: { ids: [ @ebook.id.to_s ] }
    assert_response :unprocessable_entity
  end

  test "the downloads page needs a session and the reader marks what can be kept offline" do
    get consumer_downloads_path
    assert_redirected_to new_session_path
    sign_in_as(users(:one))
    get consumer_downloads_path
    assert_response :success
    assert_select "[data-controller=consumer-downloads][data-consumer-downloads-account-value=?]", users(:one).id.to_s
    assert_select "body[data-controller=consumer-offline-presence][data-consumer-offline-presence-max-age-days-value='30']"

    get consumer_publication_path(@ebook)
    publication = JSON.parse(css_select("script[data-consumer-reader-target=publication]").sole.text)
    assert_equal({ "supported" => true }, publication.fetch("offline"))
    assert_select "[data-consumer-reader-target=controls] [data-controller=consumer-offline][hidden]"

    File.open(@epub_path, "r+") { |file| file.truncate(33.megabytes) }
    get consumer_publication_path(@ebook)
    publication = JSON.parse(css_select("script[data-consumer-reader-target=publication]").sole.text)
    assert_equal({ "supported" => false }, publication.fetch("offline"))

    get consumer_publication_path(@audiobook)
    assert_select ".consumer-audio-panel [data-controller=consumer-offline]"
  end

  test "only formats the web reader can reopen are offered for offline use" do
    controller = Consumer::OfflineController.new
    epub = { format: "epub", media_type: "application/epub+zip", size_bytes: 10 }
    supported = ->(type, *assets) { controller.send(:web_offline_supported?, { book_type: type, assets: assets }) }
    assert supported.call("ebook", epub)
    assert_not supported.call("ebook")
    assert_not supported.call("ebook", epub.merge(size_bytes: 33.megabytes))
    assert supported.call("ebook", epub, { format: "cbz", media_type: "application/vnd.comicbook+zip", size_bytes: 10 })
    assert supported.call("ebook", { format: "pdf", media_type: "application/pdf", size_bytes: 400.megabytes })
    assert_not supported.call("ebook", { format: "pdf", media_type: "application/pdf", size_bytes: 10 }, epub.merge(size_bytes: 33.megabytes))
    assert_not supported.call("ebook", { format: "cbr", media_type: "application/x-cbr", size_bytes: 10 })
    assert supported.call("audiobook", { format: "mp3", media_type: "audio/mpeg", size_bytes: 10 })
  end

  test "the sign-in page forgets this browser's offline account" do
    get new_session_path
    assert_select "[data-controller=consumer-offline-signed-out][data-consumer-offline-signed-out-base-value='']"
  end

  private

  def worker_config
    JSON.parse(response.body[/\Aself\.SHELFARR_OFFLINE = (.+?);\n/, 1])
  end
end
