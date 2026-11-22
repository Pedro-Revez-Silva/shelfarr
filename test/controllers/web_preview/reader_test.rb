# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"
require_relative "../../test_helpers/fixed_layout_fixtures"
require_relative "../../test_helpers/read_along_fixtures"

class WebPreview::ReaderTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper
  include FixedLayoutFixtures
  include ReadAlongFixtures

  READER_POLICY = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline' blob:; font-src 'self' blob: data:; " \
    "img-src 'self' https: blob: data:; media-src 'self'; connect-src 'self'; frame-src 'self'; manifest-src 'none'; " \
    "form-action 'none'; base-uri 'self'; frame-ancestors 'self'; object-src 'none'"

  setup do
    prepare_consumer_library
    Book.where.not(id: [ @ebook.id, @audiobook.id ]).update_all(file_path: nil)
    @comic_path = File.join(@root, "A Comic.cbz")
    File.binwrite(@comic_path, fixed_layout_zip(comic_pages(3, width: 8, height: 8)))
    @comic = Book.create!(title: "A Comic", author: "An Artist", book_type: :comicbook, file_path: @comic_path)
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ users(:one), users(:two) ].map { |user| user.id.to_s }.join(",")
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def comic_asset
    Consumer::LibraryAssets.new(@comic, formats: %w[cbz]).list.sole
  end

  def boot
    JSON.parse(css_select("script#shelfarr-boot").sole.text)
  end

  def media_path(book, asset_id, account: users(:one))
    web_preview_api_media_path(account: account.id, id: book.id, asset_id: asset_id)
  end

  def put_progress(book, body, headers: {})
    put web_preview_api_progress_path(id: book.id), params: body, headers: account_headers(users(:one)).merge(headers), as: :json
  end

  def bootstrap_token
    get web_preview_api_auth_bootstrap_path
    response.parsed_body.fetch("csrf_token")
  end

  test "the reader and Downloads shells are the same static documents for everyone, with the Go boot shape and Rails' own engines" do
    sign_in_as(users(:one))
    get web_preview_reader_path(id: @ebook.id)
    assert_response :success
    assert_equal READER_POLICY, response.headers["Content-Security-Policy"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_select "meta[name=csrf-token]", count: 0
    assert_select "script:not([type='application/json']):not([src])", count: 0
    reader_boot = boot
    assert_equal %w[api classic_downloads mount offline page_engine reader_engine reader_formats runtime version view], reader_boot.keys.sort
    assert_equal [ 1, "rails", "reader", "/preview", "/preview/api/v1", "/read/downloads", %w[cbz epub pdf] ],
      reader_boot.values_at("version", "runtime", "view", "mount", "api", "classic_downloads", "reader_formats")
    assert_equal({ "worker" => "/preview/offline-worker.js", "scope" => "/preview/library/", "downloads" => "/preview/library/downloads" }, reader_boot.fetch("offline"))
    assert_match(%r{\A/assets/consumer_reader_engine-\h+\.js\z}, reader_boot.fetch("reader_engine"))
    page_engine = reader_boot.fetch("page_engine")
    assert_match(%r{\A/assets/consumer_pdf_engine-\h+\.js\z}, page_engine.fetch("engine"))
    assert_match(%r{\A/assets/pdfjs/pdf\.worker-\h+\.js\z}, page_engine.fetch("worker"))
    assert_equal %w[cMapUrl standardFontDataUrl wasmUrl], page_engine.fetch("files").keys.sort
    assert_not_includes response.body, users(:one).id.to_s.then { |id| "\"account\":\"#{id}\"" }
    assert_not_includes response.body, @ebook.title
    first = response.body

    sign_out
    sign_in_as(users(:two))
    get web_preview_reader_path(id: @audiobook.id)
    assert_equal first, response.body

    get web_preview_downloads_path
    assert_response :success
    assert_equal WebPreview::ShellController::CONTENT_SECURITY_POLICY, response.headers["Content-Security-Policy"]
    assert_equal %w[api classic_downloads mount offline reader_formats runtime version view], boot.keys.sort
    assert_equal "downloads", boot.fetch("view")
  end

  test "the reader shells keep the preview's access rules" do
    get web_preview_reader_path(id: @ebook.id)
    assert_redirected_to new_session_path
    get web_preview_downloads_path
    assert_redirected_to new_session_path
    with_preview_users(users(:two)) do
      sign_in_as(users(:one))
      get web_preview_reader_path(id: @ebook.id)
      assert_response :not_found
      get web_preview_downloads_path
      assert_response :not_found
    end
    with_env(WebPreview::Access::VARIABLE => nil) do
      get web_preview_reader_path(id: @ebook.id)
      assert_response :not_found
    end
  end

  test "every reader route is not found when the preview is off or the account is not on the list" do
    sign_in_as(users(:one))
    audio = consumer_asset(@audiobook).id
    paths = [ web_preview_api_reader_path(id: @audiobook.id), web_preview_api_progress_path(id: @audiobook.id),
      web_preview_api_reading_order_path(id: @comic.id, asset_id: comic_asset.id), media_path(@audiobook, audio) ]
    [ { WebPreview::Access::VARIABLE => nil }, { WebPreview::Access::VARIABLE => users(:two).id.to_s } ].each do |env|
      with_env(env) do
        paths.each do |path|
          preview_get path
          assert_response :not_found, "#{env} #{path}"
          assert_equal({ "error" => "not_found" }, response.parsed_body)
        end
        put_progress(@audiobook, audio_progress(asset_id: audio))
        assert_response :not_found
      end
    end
    assert_equal 0, ConsumerProgress.count
  end

  test "the session adapter answers the Go bootstrap shape from the Rails cookie session" do
    get web_preview_api_auth_bootstrap_path
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    signed_out = response.parsed_body
    assert_equal({ "authenticated" => false, "expires_in" => 7200, "sign_in" => { "available" => false, "reason" => "rails_sign_in" } }, signed_out.except("csrf_token"))
    assert_predicate signed_out.fetch("csrf_token"), :present?

    sign_in_as(users(:one))
    travel_to(Time.current) do
      Current.reset
      Session.where(user: users(:one)).update_all(created_at: 10.days.ago)
      get web_preview_api_auth_bootstrap_path
      body = response.parsed_body
      assert_equal({ "authenticated" => true, "account" => users(:one).id.to_s, "expires_in" => 7200, "offline_expires_in" => 20.days.to_i }, body.except("csrf_token"))
      SettingsService.set(:session_max_age_days, 90)
      get web_preview_api_auth_bootstrap_path
      assert_equal 30.days.to_i, response.parsed_body.fetch("offline_expires_in")
    end

    with_preview_users(users(:two)) do
      get web_preview_api_auth_bootstrap_path
      assert_response :not_found
      assert_equal({ "error" => "not_found" }, response.parsed_body)
    end
    with_env(WebPreview::Access::VARIABLE => "") do
      sign_out
      get web_preview_api_auth_bootstrap_path
      assert_response :not_found
    end
  end

  def sign_in_with_expiring_cookie(user, expires:)
    Current.session = user.sessions.create!
    ActionDispatch::TestRequest.create.cookie_jar.tap do |jar|
      jar.signed[:session_id] = { value: Current.session.id, expires: expires }
      cookies["session_id"] = jar[:session_id]
    end
  end

  test "the offline window never outlives the signed session cookie, even after the session lifetime is raised" do
    freeze_time do
      sign_in_with_expiring_cookie(users(:one), expires: 10.days.from_now)
      Session.where(user: users(:one)).update_all(created_at: 20.days.ago)
      SettingsService.set(:session_max_age_days, 90)
      get web_preview_api_auth_bootstrap_path
      assert_equal 10.days.to_i, response.parsed_body.fetch("offline_expires_in")
      SettingsService.set(:session_max_age_days, 25)
      get web_preview_api_auth_bootstrap_path
      assert_equal 5.days.to_i, response.parsed_body.fetch("offline_expires_in")
    end
  end

  test "errors are private and the off switch answers 404 before any cross-site refusal" do
    get web_preview_api_reader_path(id: @ebook.id), headers: account_headers(users(:one))
    assert_response :unauthorized
    assert_equal "private, no-store", response.headers["Cache-Control"]
    with_env(WebPreview::Access::VARIABLE => nil) do
      get web_preview_api_reading_order_path(id: @comic.id, asset_id: comic_asset.id), headers: { "Sec-Fetch-Site" => "cross-site" }
      assert_response :not_found
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end
  end

  test "the bootstrap token is the Rails form token, so a progress write with it passes forgery protection and one without it does not" do
    sign_in_as(users(:one))
    asset = consumer_asset(@audiobook)
    with_forgery_protection do
      put_progress(@audiobook, audio_progress(asset_id: asset.id))
      assert_response :unprocessable_entity
      assert_equal({ "error" => "invalid_csrf" }, response.parsed_body)
      assert_equal 0, ConsumerProgress.count
      put_progress(@audiobook, audio_progress(asset_id: asset.id), headers: { "X-CSRF-Token" => bootstrap_token })
      assert_response :success
    end
    assert_equal 17.5, ConsumerProgress.sole.position_seconds
  end

  test "the reader publication lists every browser format with account-bound media and the shared place" do
    sign_in_as(users(:one))
    Consumer::ProgressWriter.new(user: users(:one), book: @audiobook).call(audio_progress.stringify_keys)
    preview_get web_preview_api_reader_path(id: @audiobook.id)
    assert_response :success
    asset = consumer_asset(@audiobook)
    progress = ConsumerProgress.sole
    assert_equal({ "account" => users(:one).id.to_s, "publication" => {
      "id" => @audiobook.id.to_s, "title" => "A Listening Life", "author" => "A. Listener", "book_type" => "audiobook", "content_kind" => "book",
      "reading_status" => "in_progress",
      "assets" => [ { "id" => asset.id, "filename" => "An Audio Book.mp3", "format" => "mp3", "media_type" => "audio/mpeg", "size_bytes" => 30, "position" => 0,
        "url" => "/preview/api/v1/accounts/#{users(:one).id}/library/#{@audiobook.id}/assets/#{asset.id}" } ],
      "other_formats" => [],
      "progress" => JSON.parse(progress.representation.to_json),
      "classic_reader" => { "url" => "/read/#{@audiobook.id}", "read_along" => false } } }, response.parsed_body)

    preview_get web_preview_api_reader_path(id: @comic.id)
    publication = response.parsed_body.fetch("publication")
    assert_equal [ "ebook", "graphic" ], publication.values_at("book_type", "content_kind")
    comic = publication.fetch("assets").sole
    assert_equal [ "cbz", 3, "/preview/api/v1/library/#{@comic.id}/assets/#{comic.fetch("id")}/reading_order" ], comic.values_at("format", "page_count", "reading_order_url")

    preview_get web_preview_api_reader_path(id: @ebook.id)
    assert_equal [ "epub" ], response.parsed_body.dig("publication", "assets").map { |entry| entry.fetch("format") }
    assert_nil response.parsed_body.dig("publication", "progress")
    assert_not_includes response.body, @root
    assert_equal 1, ConsumerProgress.count
  end

  test "a read-along EPUB is flagged so the reader can offer the reader that narrates it" do
    write_read_along_epub(@epub_path)
    sign_in_as(users(:one))
    preview_get web_preview_api_reader_path(id: @ebook.id)
    assert_equal({ "url" => "/read/#{@ebook.id}", "read_along" => true }, response.parsed_body.dig("publication", "classic_reader"))
  end

  test "reader, progress and reading order refuse another account, a signed-out browser and unknown books" do
    sign_in_as(users(:one))
    paths = [ web_preview_api_reader_path(id: @ebook.id), web_preview_api_progress_path(id: @ebook.id),
      web_preview_api_reading_order_path(id: @comic.id, asset_id: comic_asset.id) ]
    paths.each do |path|
      preview_get path, user: users(:two)
      assert_response :unauthorized, path
      assert_equal({ "error" => "account_changed" }, response.parsed_body)
    end
    put_progress(@audiobook, audio_progress, headers: { "X-Shelfarr-Account" => users(:two).id.to_s })
    assert_response :unauthorized
    preview_get web_preview_api_reader_path(id: 999_999)
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)
    sign_out
    paths.each do |path|
      preview_get path
      assert_response :unauthorized, path
      assert_equal({ "error" => "signed_out" }, response.parsed_body)
    end
    assert_equal 0, ConsumerProgress.count
  end

  test "progress reads and compare-and-set writes answer for the account with the native rules" do
    sign_in_as(users(:one))
    asset = consumer_asset(@audiobook)
    preview_get web_preview_api_progress_path(id: @audiobook.id)
    assert_equal({ "account" => users(:one).id.to_s, "progress" => nil }, response.parsed_body)

    first = audio_progress(asset_id: asset.id, mutation: SecureRandom.uuid, seconds: 40).merge(observed_at: 2.minutes.ago.utc.iso8601(3))
    put_progress(@audiobook, first)
    assert_response :success
    saved = response.parsed_body
    assert_equal [ users(:one).id.to_s, 1, 40.0 ], [ saved.fetch("account"), saved.dig("progress", "version"), saved.dig("progress", "position_seconds") ]

    put_progress(@audiobook, audio_progress(asset_id: asset.id, version: 0, seconds: 50).merge(observed_at: 1.minute.ago.utc.iso8601(3)))
    assert_response :conflict
    assert_equal({ "account" => users(:one).id.to_s, "error" => "progress_conflict", "progress" => saved.fetch("progress") }, response.parsed_body)

    put_progress(@audiobook, audio_progress(asset_id: "f" * 64, version: 1))
    assert_response :unprocessable_entity
    assert_equal "invalid_progress", response.parsed_body.fetch("error")

    preview_get web_preview_api_progress_path(id: @audiobook.id)
    assert_equal saved, response.parsed_body
    assert_equal 1, ConsumerProgress.sole.version
  end

  test "media is served only for the account named in its path, from this site, with ranges and privacy headers" do
    sign_in_as(users(:one))
    asset = consumer_asset(@audiobook)
    get media_path(@audiobook, asset.id), headers: { "Range" => "bytes=0-4", "Sec-Fetch-Site" => "same-origin" }
    assert_response :partial_content
    assert_equal "an au", response.body
    assert_equal [ "private, no-store", "same-origin", "no-referrer", "nosniff", %("#{asset.id}"), "bytes 0-4/30" ],
      response.headers.values_at("Cache-Control", "Cross-Origin-Resource-Policy", "Referrer-Policy", "X-Content-Type-Options", "ETag", "Content-Range")
    assert_equal ConsumerMediaResponse::DOCUMENT_POLICY, response.headers["Content-Security-Policy"]
    get media_path(@ebook, consumer_asset(@ebook).id)
    assert_response :success
    assert_equal File.binread(@epub_path), response.body.b

    get media_path(@audiobook, asset.id, account: users(:two))
    assert_response :unauthorized
    assert_equal({ "error" => "account_changed" }, response.parsed_body)
    get media_path(@audiobook, asset.id), headers: { "Sec-Fetch-Site" => "cross-site" }
    assert_response :forbidden
    assert_equal({ "error" => "cross_site_refused" }, response.parsed_body)
    get media_path(@audiobook, consumer_asset(@ebook).id)
    assert_response :gone
    assert_equal({ "error" => "asset_unavailable" }, response.parsed_body)

    sign_out
    get media_path(@audiobook, asset.id), headers: { "Sec-Fetch-Site" => "same-site" }
    assert_response :forbidden
    get media_path(@audiobook, asset.id)
    assert_response :unauthorized
    assert_equal({ "error" => "signed_out" }, response.parsed_body)
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  test "the reading order is the comic's own page list for this account" do
    sign_in_as(users(:one))
    asset = comic_asset
    preview_get web_preview_api_reading_order_path(id: @comic.id, asset_id: asset.id)
    assert_response :success
    body = response.parsed_body
    assert_equal [ users(:one).id.to_s, asset.id, "cbz", 3 ], [ body.fetch("account"), body.fetch("asset_id"), body.fetch("format"), body.fetch("items").size ]
    assert_equal [ 1, 2, 3 ], body.fetch("items").map { |item| item.fetch("position") }
    preview_get web_preview_api_reading_order_path(id: @comic.id, asset_id: asset.id), headers: { "Sec-Fetch-Site" => "cross-site" }
    assert_response :forbidden
    preview_get web_preview_api_reading_order_path(id: @ebook.id, asset_id: consumer_asset(@ebook).id)
    assert_response :gone
    assert_equal({ "error" => "asset_unavailable" }, response.parsed_body)
  end

  test "the offline worker carries the served shells and the exact bytes of the files it precaches, with no account data" do
    get web_preview_offline_worker_path
    assert_response :success
    assert_equal [ "text/javascript; charset=utf-8", "no-cache", "default-src 'none'; connect-src 'self'", "same-origin", "nosniff" ],
      response.headers.values_at("Content-Type", "Cache-Control", "Content-Security-Policy", "Cross-Origin-Resource-Policy", "X-Content-Type-Options")
    prefix, source = response.body.split(";\n", 2)
    assert_equal File.read(WebPreview::OfflineWorkerController::SOURCE), source
    config = JSON.parse(prefix.delete_prefix("self.SHELFARR_GO_OFFLINE = "))
    assert_equal %w[assets downloads library shells version], config.keys.sort
    assert_equal [ "/preview/library", "/preview/library/downloads" ], config.values_at("library", "downloads")
    assert_match(/\A\h{24}\z/, config.fetch("version"))
    worker = response.body

    sign_in_as(users(:one))
    get web_preview_offline_worker_path
    assert_equal worker, response.body
    assert_not_includes worker, "csrf"
    { "reader" => web_preview_reader_path(id: @ebook.id), "downloads" => web_preview_downloads_path }.each do |view, path|
      get path
      shell = config.dig("shells", view)
      assert_equal response.body, shell.fetch("body"), view
      shell.fetch("headers").each { |name, value| assert_equal value, response.headers[name], "#{view} #{name}" }
    end

    stylesheet = css_select("link[rel=stylesheet]").sole["href"]
    script = css_select("script[type=module]").sole["src"]
    get stylesheet
    fonts = response.body.scan(/url\("([^"]+)"\)/).flatten
    precached = config.fetch("assets").map { |asset| asset.fetch("path") }
    assert_equal [ script, stylesheet, *fonts, boot_reader_engine ].sort, precached.sort
    config.fetch("assets").each do |asset|
      get asset.fetch("path")
      assert_response :success, asset.fetch("path")
      assert_equal Digest::SHA256.hexdigest(response.body), asset.fetch("sha256"), asset.fetch("path")
    end

    with_env(WebPreview::Access::VARIABLE => nil) do
      get web_preview_offline_worker_path
      assert_response :not_found
    end
  end

  test "the worker hashes a precompiled asset's own bytes, which are what a deployment serves" do
    output = Dir.mktmpdir("precompiled-assets")
    previous = Rails.application.config.assets.output_path
    Rails.application.config.assets.output_path = Pathname(output)
    stylesheet = Rails.application.assets.load_path.find("web/preview.css")
    FileUtils.mkdir_p(File.join(output, "web"))
    File.binwrite(File.join(output, stylesheet.digested_path.to_s), "precompiled stylesheet bytes")
    get web_preview_offline_worker_path
    config = JSON.parse(response.body.split(";\n", 2).first.delete_prefix("self.SHELFARR_GO_OFFLINE = "))
    hashes = config.fetch("assets").to_h { |asset| [ asset.fetch("path"), asset.fetch("sha256") ] }
    assert_equal Digest::SHA256.hexdigest("precompiled stylesheet bytes"), hashes.fetch(ApplicationController.helpers.asset_path("web/preview.css"))
    assert_equal Digest::SHA256.hexdigest(Rails.application.assets.load_path.find("consumer_reader_engine.js").compiled_content),
      hashes.fetch(ApplicationController.helpers.asset_path("consumer_reader_engine.js"))
  ensure
    Rails.application.config.assets.output_path = previous
    FileUtils.remove_entry(output) if output
  end

  test "a signed-in account refused by the allowlist gets a 404 page that releases its offline access, while an unconfigured preview stays a plain 404" do
    sign_in_as(users(:one))
    with_preview_users(users(:two)) do
      [ web_preview_library_path, web_preview_reader_path(id: @ebook.id), web_preview_downloads_path ].each do |path|
        get path
        assert_response :not_found, path
        imports = JSON.parse(css_select("script[type=importmap]").sole.text).fetch("imports")
        assert_match(%r{\A/assets/web_preview_access_refused-\h+\.js\z}, imports.fetch("web_preview_access_refused"))
        assert_select "script[type=module]", text: /import "web_preview_access_refused"/
        assert_not_includes response.body, "shelfarr-boot"
      end
    end
    with_env(WebPreview::Access::VARIABLE => nil) do
      get web_preview_downloads_path
      assert_response :not_found
      assert_equal Rails.public_path.join("404.html").read, response.body
    end
  end

  test "the sign-in page can load the module that releases the preview's offline account" do
    get new_session_path
    assert_response :success
    assert_select "[data-controller=consumer-offline-signed-out]"
    imports = JSON.parse(css_select("script[type=importmap]").sole.text).fetch("imports")
    assert_match(%r{\A/assets/web_preview_offline_release-\h+\.js\z}, imports.fetch("web_preview_offline_release"))
  end

  def boot_reader_engine
    get web_preview_reader_path(id: @ebook.id)
    boot.fetch("reader_engine")
  end

  test "the Library shell tells the app which formats the reader opens and where offline copies live" do
    sign_in_as(users(:one))
    get web_preview_library_path
    assert_equal [ %w[cbz epub pdf], { "worker" => "/preview/offline-worker.js", "scope" => "/preview/library/", "downloads" => "/preview/library/downloads" } ],
      boot.values_at("reader_formats", "offline")
  end
end
