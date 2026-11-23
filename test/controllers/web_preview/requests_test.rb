# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::RequestsTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  setup do
    prepare_consumer_library
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    @member = User.create!(username: "tracker_member", name: "User One", password: "Password123!", role: :user)
    @admin = User.create!(username: "tracker_admin", name: "Admin User", password: "Password123!", role: :admin)
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
    @mine = Request.create!(book: Book.create!(title: "Émile and the Lighthouse", author: "Ana Writer", book_type: :ebook, open_library_work_id: "OL700W"), user: @member, status: :searching, notes: "Second edition please")
    @theirs = Request.create!(book: Book.create!(title: "Someone Else's Book", book_type: :audiobook), user: @admin, status: :not_found, attention_needed: true, issue_description: "No copies after 3 searches")
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def list(user:, **params)
    preview_get web_preview_api_requests_path(**params), user: user
    assert_response :success
    response.parsed_body
  end

  def detail(request, user:)
    preview_get web_preview_api_request_path(request), user: user
    response.parsed_body
  end

  def post_action(path, user:, **body)
    post path, params: body, headers: account_headers(user), as: :json
    response.parsed_body
  end

  test "a member lists only their own requests, without requesters, with the same filters and counts as the classic page" do
    sign_in_as(@member)
    body = list(user: @member)
    assert_equal @member.id.to_s, body.fetch("account")
    assert_equal "own", body.fetch("scope")
    assert_equal [ @mine.id.to_s ], body.fetch("items").map { |item| item.fetch("id") }
    item = body.fetch("items").sole
    assert_not item.key?("requested_by")
    assert_equal({ "source" => "openlibrary", "id" => "OL700W" }, item.fetch("book_page"))
    assert_equal({ "attention" => 0, "active" => 1 }, body.fetch("counts"))
    assert_equal({ "status" => nil, "attention" => false, "q" => nil }, body.fetch("filter"))
    assert_equal [ 1, 25, 1, 1 ], body.values_at("page", "per_page", "total", "total_pages")
    assert_equal [], list(user: @member, status: "not_found").fetch("items")
  end

  test "an administrator lists every request with its requester, and searching folds Unicode case like the classic page" do
    sign_in_as(@admin)
    body = list(user: @admin)
    assert_equal "all", body.fetch("scope")
    ids = body.fetch("items").map { |item| item.fetch("id") }
    assert_equal [ @theirs.id.to_s, @mine.id.to_s ], ids.first(2)
    assert_equal Request.count, body.fetch("total")
    assert_equal({ "name" => "User One", "self" => false }, body.fetch("items").second.fetch("requested_by"))
    assert_equal({ "attention" => Request.needs_attention.count, "active" => Request.active.where(attention_needed: false).count }, body.fetch("counts"))
    assert_includes list(user: @admin, attention: "true").fetch("items").map { |item| item.fetch("id") }, @theirs.id.to_s
    assert_not_includes list(user: @admin, attention: "true").fetch("items").map { |item| item.fetch("id") }, @mine.id.to_s
    assert_equal [ @mine.id.to_s ], list(user: @admin, q: "  ÉMILE ").fetch("items").map { |item| item.fetch("id") }
    assert_equal "ÉMILE", list(user: @admin, q: "  ÉMILE ").dig("filter", "q")
    preview_get web_preview_api_requests_path(status: "everything"), user: @admin
    assert_response :bad_request
  end

  test "a member sees their own request's details and actions but not another account's request, copies or diagnostics" do
    @mine.search_results.create!(guid: "copy", title: "Émile.epub", source: SearchResult::SOURCE_GUTENBERG, download_url: "https://files.example.test/e.epub")
    @mine.update!(attention_needed: true, issue_description: "Émile.epub from Gutenberg needs a choice")
    RequestEvent.record!(request: @mine, event_type: "dispatch_failed", source: "test", message: "Client down", level: :error)
    sign_in_as(@member)
    request = detail(@mine, user: @member).fetch("request")
    assert_nil request.fetch("attention_reason")
    assert request.fetch("choice_needed")
    assert_not_includes response.body, "Émile.epub"
    assert_equal "Second edition please", request.fetch("notes")
    assert_equal({ "cancel" => true, "remove" => nil, "withdraw" => WebPreview::RequestJson.withdrawal_offer(@mine).stringify_keys,
      "retry" => false, "search_again" => false, "manual_download" => false, "replaces_library_file" => false, "upload_url" => nil, "download_url" => nil }, request.fetch("actions"))
    assert_not request.key?("copies")
    assert_not request.key?("events")
    detail(@theirs, user: @member)
    assert_response :not_found
  end

  test "an administrator sees copies, diagnostics, the attention reason and every admin action" do
    @theirs.search_results.create!(guid: "copy", title: "Audio.m4b", source: SearchResult::SOURCE_GUTENBERG, download_url: "https://files.example.test/a.m4b")
    RequestEvent.record!(request: @theirs, event_type: "dispatch_failed", source: "test", message: "Client down", level: :error)
    sign_in_as(@admin)
    request = detail(@theirs, user: @admin).fetch("request")
    assert_equal "No copies after 3 searches", request.fetch("attention_reason")
    assert_equal({ "name" => "Admin User", "self" => true }, request.fetch("requested_by"))
    assert_equal %w[admin_remove], [ request.dig("actions", "remove") ]
    assert request.dig("actions", "retry")
    assert request.dig("actions", "search_again")
    assert request.dig("actions", "manual_download")
    assert_equal "/admin/uploads/new?request_id=#{@theirs.id}", request.dig("actions", "upload_url")
    assert_equal [ "Audio.m4b" ], request.dig("copies", "candidates").map { |copy| copy.fetch("title") }
    assert request.dig("copies", "selectable")
    assert_equal [ { "title" => "Dispatch Failed", "message" => "Client down", "level" => "error" } ], request.fetch("events").map { |event| event.except("at") }
  end

  def magnet(letter)
    "magnet:?xt=urn:btih:#{letter * 40}"
  end

  def revision(request)
    WebPreview::RequestJson.copies_revision(request.reload)
  end

  def choose(request, result, user: @admin, **body)
    post_action(web_preview_api_request_selection_path(request), user: user, result_id: result.id.to_s, **body)
  end

  test "an administrator's copies carry every fact and choice the classic Manage Results screen showed, and a member gets none of them" do
    chosen = @mine.search_results.create!(guid: "chosen", title: "Emile.Retail.epub", source: SearchResult::SOURCE_PROWLARR, indexer: "TorrentLeech", magnet_url: magnet("a"),
      seeders: 40, leechers: 2, confidence_score: 96, detected_language: "en", status: :selected, info_url: "https://tracker.example/t/1",
      score_breakdown: { "extension" => "epub", "preference_adjustment" => -5, "file_size_adjustment" => -20, "file_size_status" => "above_max", "auto_select_allowed" => false })
    blocked = @mine.search_results.create!(guid: "blocked", title: "Emile.de.m4b", source: SearchResult::SOURCE_JACKETT, indexer: "Jackett", download_url: "https://indexer.example/b.torrent",
      seeders: 3, confidence_score: 70, detected_language: "de", status: :rejected, blocklisted_at: Time.current, blocklist_reason: "Import failed: not a book", info_url: "javascript:alert(1)",
      score_breakdown: { "extension" => "m4b", "audiobook_structure" => "single_file", "audio_bitrate_kbps" => 128, "auto_select_allowed" => true })
    other = @mine.search_results.create!(guid: "other", title: "Emile.pdf", source: SearchResult::SOURCE_GUTENBERG, download_url: "https://files.example.test/e.pdf", confidence_score: 80, status: :rejected)
    @mine.search_results.create!(guid: "nolink", title: "Emile.nolink", source: SearchResult::SOURCE_PROWLARR, indexer: "Prowlarr", status: :rejected)
    @mine.search_results.create!(guid: "fresh", title: "Emile.fresh", source: SearchResult::SOURCE_PROWLARR, indexer: "Prowlarr", magnet_url: magnet("c"))
    @mine.update!(status: :downloading)

    sign_in_as(@admin)
    copies = detail(@mine, user: @admin).dig("request", "copies")
    assert_equal "English", copies.fetch("looking_for")
    assert_equal false, copies.fetch("selectable")
    assert_equal "Cannot refresh search while an acquisition or library import is active or awaiting recovery.", copies.fetch("search_blocked")
    by_title = copies.fetch("candidates").index_by { |copy| copy.fetch("title") }
    assert_equal "TorrentLeech", by_title.fetch("Emile.Retail.epub").fetch("source")
    assert_equal({ "choice" => "selected", "indexer" => nil, "seeders" => 40, "leechers" => 2, "score" => 96, "high_confidence" => true, "language_matches" => true,
      "structure" => nil, "bitrate_kbps" => nil, "preference_adjustment" => -5,
      "size_limit" => { "label" => "Size -20 (too large)", "explanation" => "Larger than the configured maximum file size" },
      "manual_review" => true, "blocklist_reason" => nil, "info_url" => "https://tracker.example/t/1" }, by_title.fetch("Emile.Retail.epub").fetch("details"))
    assert_equal({ "choice" => "retry_anyway", "indexer" => nil, "seeders" => 3, "leechers" => nil, "score" => 70, "high_confidence" => false, "language_matches" => false,
      "structure" => "single_file", "bitrate_kbps" => 128, "preference_adjustment" => 0, "size_limit" => nil,
      "manual_review" => false, "blocklist_reason" => "Import failed: not a book", "info_url" => nil }, by_title.fetch("Emile.de.m4b").fetch("details"))
    assert_equal({ "id" => blocked.id.to_s, "title" => "Emile.de.m4b", "format" => "M4B", "size_bytes" => nil, "language" => "German", "source" => "Jackett",
      "state" => "rejected", "skipped" => true, "downloadable" => true }, by_title.fetch("Emile.de.m4b").except("details"))
    assert_equal %w[selected retry_anyway select_instead skipped select],
      [ chosen, blocked, other ].map { |result| by_title.fetch(result.title).dig("details", "choice") } + %w[Emile.nolink Emile.fresh].map { |title| by_title.fetch(title).dig("details", "choice") }

    sign_in_as(@member)
    request = detail(@mine, user: @member).fetch("request")
    assert_not request.key?("copies")
    %w[Emile.Retail.epub TorrentLeech tracker.example Import\ failed].each { |fact| assert_not_includes response.body, fact }
    assert_equal "downloading", request.fetch("status")
    choose(@mine, other, user: @member, expected_revision: revision(@mine))
    assert_response :not_found
    assert chosen.reload.selected?
  end

  test "an administrator chooses another copy instead of the one downloading, and the running download is replaced" do
    chosen = @theirs.search_results.create!(guid: "chosen", title: "Audio.m4b", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"), status: :selected)
    running = @theirs.downloads.create!(name: "Audio.m4b", search_result: chosen, status: :queued)
    instead = @theirs.search_results.create!(guid: "instead", title: "Audio.Other.m4b", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"), status: :rejected)
    @theirs.update!(status: :downloading, attention_needed: false)
    sign_in_as(@admin)

    choose(@theirs, instead)
    assert_response :conflict
    assert_equal "not_selectable", response.parsed_body.fetch("error")
    assert chosen.reload.selected?

    body = choose(@theirs, instead, expected_revision: revision(@theirs), replace_library_file: false)
    assert_response :success
    assert_equal({ "id" => @theirs.id.to_s, "status" => "downloading" }, body.fetch("request"))
    assert instead.reload.selected?
    assert chosen.reload.rejected?
    assert_not_equal "queued", running.reload.status
    assert_equal [ instead.id ], @theirs.downloads.where(status: :queued).pluck(:search_result_id)
  end

  test "a repeated choice changes nothing, and a choice made on copies that changed meanwhile is refused" do
    first = @mine.search_results.create!(guid: "first", title: "Emile.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"))
    second = @mine.search_results.create!(guid: "second", title: "Emile.Second.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"))
    sign_in_as(@admin)

    seen = revision(@mine)
    choose(@mine, first, expected_revision: seen, replace_library_file: false)
    assert_response :success
    assert first.reload.selected?
    assert_no_difference -> { Download.count } do
      choose(@mine, first, expected_revision: seen, replace_library_file: false)
      assert_response :success
    end

    assert_no_difference -> { Download.count } do
      body = choose(@mine, second, expected_revision: seen, replace_library_file: false)
      assert_response :conflict
      assert_equal "copies_changed", body.fetch("error")
      assert_equal WebPreview::RequestsController::COPIES_CHANGED, body.fetch("message")
    end
    assert first.reload.selected?

    choose(@mine, second, expected_revision: 7, replace_library_file: false)
    assert_response :bad_request
    choose(@mine, first.tap { first.update!(magnet_url: nil, status: :rejected) }, expected_revision: revision(@mine))
    assert_response :conflict
    assert_equal "not_selectable", response.parsed_body.fetch("error")
  end

  test "a choice read before a download failed or was retried is refused rather than undoing the newer attempt" do
    SettingsService.set(:auto_select_enabled, false)
    first = @mine.search_results.create!(guid: "first", title: "Emile.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"))
    second = @mine.search_results.create!(guid: "second", title: "Emile.Second.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"))
    sign_in_as(@admin)

    before_choice = revision(@mine)
    choose(@mine, first, expected_revision: before_choice, replace_library_file: false)
    assert_response :success
    @mine.reload.handle_download_failure!(@mine.downloads.sole, reason: "the archive held no book")
    assert first.reload.blocklisted?
    assert_no_difference -> { Download.count } do
      assert_equal "copies_changed", choose(@mine, first, expected_revision: before_choice, replace_library_file: false).fetch("error")
    end
    assert first.reload.blocklisted?

    choose(@mine, first, expected_revision: revision(@mine), replace_library_file: false)
    assert_response :success
    read_while_downloading = revision(@mine)
    retried = @mine.downloads.create!(name: first.title, search_result: first, status: :queued)
    assert_equal "copies_changed", choose(@mine, second, expected_revision: read_while_downloading, replace_library_file: false).fetch("error")
    assert_equal "queued", retried.reload.status
    assert first.reload.selected?
  end

  test "a choice read before the request was cancelled is refused rather than restarting it" do
    first = @theirs.search_results.create!(guid: "first", title: "Audio.m4b", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"))
    second = @theirs.search_results.create!(guid: "second", title: "Audio.Other.m4b", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"))
    sign_in_as(@admin)
    choose(@theirs, first, expected_revision: revision(@theirs), replace_library_file: false)
    read_before_cancelling = revision(@theirs)

    post_action(web_preview_api_request_cancel_path(@theirs), user: @admin)
    assert_response :success
    assert_no_difference -> { Download.count } do
      assert_equal "copies_changed", choose(@theirs, second, expected_revision: read_before_cancelling, replace_library_file: false).fetch("error")
      assert_equal "copies_changed", choose(@theirs, first, expected_revision: read_before_cancelling, replace_library_file: false).fetch("error")
    end
    assert_equal "failed", @theirs.reload.status
    assert_not second.reload.selected?
  end

  test "a choice read before a new search rewrote the same copy in place is refused" do
    rewritten = @mine.search_results.create!(guid: "same-guid", title: "Emile and the Lighthouse Old EPUB", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"),
      status: :rejected, blocklisted_at: Time.current, blocklist_reason: "Import failed")
    sign_in_as(@admin)
    read_before_search = detail(@mine, user: @admin).dig("request", "copies", "revision")

    rewritten.update!(title: "Emile and the Lighthouse Different EPUB", magnet_url: magnet("c"))
    assert_no_difference -> { Download.count } do
      assert_equal "copies_changed", choose(@mine, rewritten, expected_revision: read_before_search, replace_library_file: false).fetch("error")
    end
    assert rewritten.reload.blocklisted?
  end

  test "the copies and their revision describe the same moment even when a choice lands while the request is read" do
    seen = @mine.search_results.create!(guid: "seen", title: "Emile.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"))
    landing = @mine.search_results.create!(guid: "landing", title: "Emile.Landing.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"))
    @mine.select_result!(seen)
    original = WebPreview::RequestJson.method(:copies_revision)
    choice_lands = lambda do |request|
      request.select_result!(landing.reload) unless landing.reload.selected?
      original.call(request)
    end
    sign_in_as(@admin)
    copies = WebPreview::RequestJson.stub(:copies_revision, choice_lands) { detail(@mine, user: @admin).dig("request", "copies") }

    shown = copies.fetch("candidates").select { |copy| copy.dig("details", "choice") == "selected" }.map { |copy| copy.fetch("id") }
    assert_equal [ landing.id.to_s ], shown
    assert_equal revision(@mine), copies.fetch("revision")
  end

  test "a choice read before its provider was edited is refused" do
    provider = AcquisitionProvider.create!(name: "Shelf Provider", url: "http://provider.test", enabled: true, supports_ebooks: true, priority: 0, timeout_seconds: 30)
    offered = @mine.search_results.create!(guid: "custom", title: "Emile.epub", source: SearchResult::SOURCE_CUSTOM, acquisition_provider: provider,
      provider_result_id: "42", provider_payload: { "download_type" => "torrent", "magnet_url" => magnet("a") })
    sign_in_as(@admin)
    read_before_edit = detail(@mine, user: @admin).dig("request", "copies", "revision")

    provider.update!(name: "Other Provider", url: "http://other-provider.test")
    assert_no_difference -> { Download.count } do
      assert_equal "copies_changed", choose(@mine, offered, expected_revision: read_before_edit, replace_library_file: false).fetch("error")
    end
  end

  test "a cancellation that lands while the request is read is shown together with the revision it produced" do
    first = @theirs.search_results.create!(guid: "first", title: "Audio.m4b", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"))
    @theirs.search_results.create!(guid: "second", title: "Audio.Other.m4b", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"))
    @theirs.select_result!(first)
    original = WebPreview::RequestJson.method(:copies_revision)
    calls = 0
    cancel_mid_read = lambda do |request|
      calls += 1
      Request.find(request.id).cancel! if calls == 2
      original.call(request)
    end
    sign_in_as(@admin)
    request = WebPreview::RequestJson.stub(:copies_revision, cancel_mid_read) { detail(@theirs, user: @admin).fetch("request") }

    assert_equal "failed", request.fetch("status")
    assert_equal [ "failed" ], request.fetch("downloads").map { |download| download.fetch("status") }
    assert_equal revision(@theirs), request.dig("copies", "revision")
  end

  test "an administrator's request read never answers from the query cache, so a write from another connection is seen on the second look" do
    @theirs.search_results.create!(guid: "first", title: "Audio.m4b", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"))
    sign_in_as(@admin)
    cached = []
    record = ->(*, payload) { cached << payload[:sql] if payload[:cached] }
    ActiveSupport::Notifications.subscribed(record, "sql.active_record") { detail(@theirs, user: @admin) }
    assert_response :success
    assert_equal [], cached
  end

  test "an unreadable scoring detail on one copy leaves the request and the copy's other facts readable" do
    @theirs.search_results.create!(guid: "odd", title: "Odd.m4b", source: SearchResult::SOURCE_PROWLARR, indexer: "Prowlarr", magnet_url: magnet("a"), seeders: 5, confidence_score: 60,
      score_breakdown: { "audiobook_structure" => 1, "preference_adjustment" => [ 1 ], "auto_select_allowed" => true })
    sign_in_as(@admin)
    copies = detail(@theirs, user: @admin).dig("request", "copies")
    assert_response :success
    assert_equal({ "structure" => nil, "bitrate_kbps" => nil, "preference_adjustment" => 0, "size_limit" => nil, "seeders" => 5, "score" => 60 },
      copies.fetch("candidates").sole.fetch("details").slice("structure", "bitrate_kbps", "preference_adjustment", "size_limit", "seeders", "score"))
    assert_match(/\A\h{32}\z/, copies.fetch("revision"))
  end

  test "choosing a copy for a book already in the library replaces its file only when the administrator confirms it" do
    @mine.update!(book: @ebook, status: :completed, completed_at: Time.current)
    kept = @mine.search_results.create!(guid: "kept", title: "Kept.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"), status: :selected)
    better = @mine.search_results.create!(guid: "better", title: "Better.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"), status: :rejected)
    sign_in_as(@admin)
    request = detail(@mine, user: @admin).fetch("request")
    assert request.dig("actions", "replaces_library_file")
    assert_equal "select_instead", request.dig("copies", "candidates").find { |copy| copy.fetch("id") == better.id.to_s }.dig("details", "choice")

    assert_no_difference -> { Download.count } do
      body = choose(@mine, better, expected_revision: revision(@mine), replace_library_file: false)
      assert_response :conflict
      assert_equal "replacement_unconfirmed", body.fetch("error")
    end
    assert_no_difference -> { Download.count } do
      choose(@mine, better, expected_revision: revision(@mine), replace_library_file: "1")
      assert_response :conflict
    end

    choose(@mine, better, expected_revision: revision(@mine), replace_library_file: true)
    assert_response :success
    assert better.reload.selected?
    assert_equal [ true ], @mine.downloads.where(search_result: better).pluck(:replace_library_file)
    assert_equal @ebook.file_path, @ebook.reload.file_path
  end

  test "a replacement confirmed on a page read before another request replaced the same book's file is refused" do
    @mine.update!(book: @ebook, status: :completed, completed_at: Time.current)
    kept = @mine.search_results.create!(guid: "kept", title: "Kept.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"), status: :selected)
    better = @mine.search_results.create!(guid: "better", title: "Better.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"), status: :rejected)
    Request.create!(book: @ebook, user: @admin, status: :completed, completed_at: Time.current)
    sign_in_as(@admin)
    read_before_other_import = detail(@mine, user: @admin).dig("request", "copies", "revision")

    @ebook.update!(file_path: "#{@ebook.file_path}.replaced")
    assert_no_difference -> { Download.count } do
      assert_equal "copies_changed", choose(@mine, better, expected_revision: read_before_other_import, replace_library_file: true).fetch("error")
    end
    assert kept.reload.selected?
  end

  test "a skipped copy can be tried again anyway, which lifts its blocklist like the classic Retry Anyway" do
    blocked = @mine.search_results.create!(guid: "blocked", title: "Emile.epub", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"), status: :rejected,
      blocklisted_at: Time.current, blocklist_reason: "Import failed")
    @mine.update!(status: :not_found)
    sign_in_as(@admin)
    choose(@mine, blocked, expected_revision: revision(@mine), replace_library_file: false)
    assert_response :success
    assert_not blocked.reload.blocklisted?
    assert blocked.selected?
    assert_equal "downloading", @mine.reload.status
  end

  test "automatic selection still downloads a qualifying copy with no step in the interface, and the inspector only reports it afterwards" do
    best = @mine.search_results.create!(guid: "best", title: "Emile and the Lighthouse EPUB", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("a"), seeders: 10, confidence_score: 95, detected_language: "en")
    @mine.search_results.create!(guid: "worse", title: "Emile and the Lighthouse PDF", source: SearchResult::SOURCE_PROWLARR, magnet_url: magnet("b"), seeders: 1, confidence_score: 50, detected_language: "en")
    %i[ebook_approved_formats ebook_rejected_formats ebook_preferred_formats].each { |key| SettingsService.set(key, []) }
    outcome = AutoSelectService.call(@mine)
    assert outcome.success?, outcome.reason.inspect
    assert best.reload.selected?
    assert_equal "downloading", @mine.reload.status

    sign_in_as(@admin)
    copies = detail(@mine, user: @admin).dig("request", "copies")
    assert_equal false, copies.fetch("selectable")
    assert_equal %w[selected select_instead], copies.fetch("candidates").map { |copy| copy.dig("details", "choice") }

    sign_in_as(@member)
    request = detail(@mine, user: @member).fetch("request")
    assert_equal [ "downloading", false ], request.values_at("status", "choice_needed")
    assert_not request.key?("copies")
  end

  test "a completed request links to the library copy the browser opens and offers its download and history removal to its owner" do
    @mine.update!(book: @ebook, status: :completed, completed_at: Time.current)
    sign_in_as(@member)
    request = detail(@mine, user: @member).fetch("request")
    assert_equal({ "state" => "available", "publication_id" => @ebook.id.to_s }, request.fetch("library"))
    assert_equal "delete_history", request.dig("actions", "remove")
    assert_not request.dig("actions", "cancel")
    assert_equal "/requests/#{@mine.id}/download", request.dig("actions", "download_url")
    assert_equal({ "status" => "removed", "id" => @mine.id.to_s }, post_action(web_preview_api_request_remove_path(@mine), user: @member).fetch("request"))
    assert_not Request.exists?(@mine.id)
    assert Book.exists?(@ebook.id)
  end

  test "a member cannot delete an unfinished request, retry, add a link or act on another account's request" do
    sign_in_as(@member)
    assert_equal "cannot_remove", post_action(web_preview_api_request_remove_path(@mine), user: @member).fetch("error")
    assert_response :conflict
    post_action(web_preview_api_request_remove_path(@theirs), user: @member)
    assert_response :not_found
    post_action(web_preview_api_request_retry_path(@mine), user: @member)
    assert_response :not_found
    post_action(web_preview_api_request_manual_path(@mine), user: @member, kind: "magnet", url: "magnet:?xt=urn:btih:#{"a" * 40}")
    assert_response :not_found
    assert Request.exists?(@mine.id)
  end

  test "an administrator retries a request, removes another account's request and keeps the book of a completed one" do
    sign_in_as(@admin)
    body = post_action(web_preview_api_request_retry_path(@theirs), user: @admin)
    assert_response :success
    assert_equal @theirs.id.to_s, body.dig("request", "id")
    assert_equal "pending", @theirs.reload.status
    post_action(web_preview_api_request_remove_path(@mine), user: @admin)
    assert_response :success
    assert_not Request.exists?(@mine.id)
    @theirs.update!(book: @ebook, status: :completed, completed_at: Time.current)
    post_action(web_preview_api_request_remove_path(@theirs), user: @admin)
    assert_response :success
    assert Book.exists?(@ebook.id)
  end

  test "an administrator adds a manual link, and a bad link is refused with the model's reason" do
    sign_in_as(@admin)
    assert_equal "Enter a valid magnet link", post_action(web_preview_api_request_manual_path(@mine), user: @admin, kind: "magnet", magnet_url: "http://nope").fetch("message")
    assert_response :unprocessable_entity
    post_action(web_preview_api_request_manual_path(@mine), user: @admin, kind: "torrent", magnet_url: "x")
    assert_response :unprocessable_entity
    post_action(web_preview_api_request_manual_path(@mine), user: @admin, kind: "nzb", magnet_url: "https://indexer.example/get?apikey=secret")
    assert_response :unprocessable_entity
  end

  test "an NZB address travels in the field the logs already redact" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("nzb_url" => "https://indexer.example/get?apikey=secret").fetch("nzb_url")
  end

  test "a cancelled request no longer offers Cancel, and the existing cancel endpoint answers as before" do
    sign_in_as(@member)
    post_action(web_preview_api_request_cancel_path(@mine), user: @member)
    assert_response :success
    assert_equal [ false, nil ], detail(@mine, user: @member).dig("request", "actions").values_at("cancel", "remove")
    assert_equal "failed", post_action(web_preview_api_request_cancel_path(@mine), user: @member).dig("request", "status")
    assert_response :success
  end

  test "request actions need the page's CSRF token and every read needs the account header" do
    sign_in_as(@member)
    get web_preview_api_requests_path, headers: { "Accept" => "application/json" }
    assert_response :unauthorized
    with_forgery_protection do
      post_action(web_preview_api_request_remove_path(@mine), user: @member)
      assert_response :unprocessable_entity
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
    end
  end

  test "the request tracker addresses load the preview shell" do
    sign_in_as(@member)
    get "/preview/requests"
    assert_response :success
    assert_select "#shelfarr-boot"
    get "/preview/requests/#{@mine.id}"
    assert_response :success
    get "/preview/account"
    assert_response :success
  end
end
