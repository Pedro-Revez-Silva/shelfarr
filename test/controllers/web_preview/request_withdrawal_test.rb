# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::RequestWithdrawalTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper
  include ActiveJob::TestHelper

  CHANGED = "This request changed since the page was read. The page now shows it as it is; check what removing it does and choose again."

  setup do
    prepare_consumer_library
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    @member = User.create!(username: "withdraw_member", name: "Rae Reader", password: "Password123!", role: :user)
    @other = User.create!(username: "withdraw_other", name: "Other Reader", password: "Password123!", role: :user)
    @admin = User.create!(username: "withdraw_admin", name: "Admin User", password: "Password123!", role: :admin)
    ENV[WebPreview::Access::VARIABLE] = [ @member, @other, @admin ].map { |user| user.id.to_s }.join(",")
    @book = Book.create!(title: "The Dispossessed", author: "Ursula K. Le Guin", book_type: :ebook)
    @mine = Request.create!(book: @book, user: @member, status: :downloading)
    @client = DownloadClient.create!(name: "Withdrawal client #{SecureRandom.hex(4)}", client_type: :qbittorrent, url: "http://127.0.0.1:8080", enabled: true, priority: 0)
    @removed = []
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def torrent(request = @mine, status: :downloading, external_id: "hash-#{SecureRandom.hex(6)}")
    request.downloads.create!(name: "A torrent", status: status, download_client: @client, external_id: external_id)
  end

  def withdrawal(request = @mine, user: @member)
    preview_get web_preview_api_request_path(request), user: user
    assert_response :success
    response.parsed_body.dig("request", "actions", "withdraw")
  end

  def withdraw(request = @mine, user: @member, revision: withdrawal(request, user: user)&.fetch("revision"), remove_torrent: false, adapter: recording_adapter)
    DownloadClients::Qbittorrent.stub(:new, adapter) do
      post web_preview_api_request_withdraw_path(request), params: { expected_revision: revision, remove_torrent: remove_torrent }, headers: account_headers(user), as: :json
    end
    response.parsed_body
  end

  def recording_adapter
    removed = @removed
    Object.new.tap do |adapter|
      adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
        removed << [ external_id, delete_files ]
        true
      end
    end
  end

  def unreachable_adapter
    removed = @removed
    Object.new.tap do |adapter|
      adapter.define_singleton_method(:remove_torrent) do |external_id, delete_files:|
        removed << [ external_id, delete_files ]
        raise DownloadClients::Base::ConnectionError, "client down"
      end
    end
  end

  def cancellations
    ActivityLog.for_action("request.cancelled").count
  end

  test "the requester's unfinished request offers removal with the torrents it can also remove, and nobody else is offered it" do
    first = torrent
    torrent(status: :failed)
    @mine.downloads.create!(name: "Direct", status: :failed)
    @mine.downloads.create!(name: "No id", status: :failed, download_client: @client)
    sign_in_as(@member)
    offer = withdrawal
    assert_equal [ "revision", "torrents" ], offer.keys
    assert_match(/\A[0-9a-f]{32}\z/, offer.fetch("revision"))
    assert_equal 2, offer.fetch("torrents")
    assert_equal offer, withdrawal, "the same state reads as the same revision"
    first.update!(progress: 60)
    assert_equal offer, withdrawal, "download progress does not change what removal does"

    sign_in_as(@other)
    preview_get web_preview_api_request_path(@mine), user: @other
    assert_response :not_found
    sign_in_as(@admin)
    assert_nil withdrawal(user: @admin)
    assert_equal "admin_remove", response.parsed_body.dig("request", "actions", "remove")
  end

  test "every unfinished state can be removed by its requester and a finished one only offers its history" do
    sign_in_as(@member)
    Request.statuses.each_key do |status|
      request = Request.create!(book: Book.create!(title: "State #{status}", book_type: :ebook), user: @member, status: status, completed_at: status == "completed" ? Time.current : nil)
      offer = withdrawal(request)
      if status == "completed"
        assert_nil offer, status
        assert_equal "delete_history", response.parsed_body.dig("request", "actions", "remove")
        assert_equal "request_changed", withdraw(request, revision: "0" * 32).fetch("error")
        assert_response :conflict
        assert Request.exists?(request.id)
      else
        assert_equal 0, offer.fetch("torrents"), status
        assert_equal({ "id" => request.id.to_s, "status" => "removed" }, withdraw(request).fetch("request"), status)
        assert_not Request.exists?(request.id), status
      end
    end
  end

  test "removing without the torrent deletes the request and its downloads, records the cancellation and leaves the download client alone" do
    download = torrent
    sign_in_as(@member)
    assert_difference -> { cancellations }, 1 do
      assert_equal({ "account" => @member.id.to_s, "request" => { "id" => @mine.id.to_s, "status" => "removed" } }, withdraw(remove_torrent: false))
    end
    assert_response :success
    assert_empty @removed
    assert_not Request.exists?(@mine.id)
    assert_not Download.exists?(download.id)
    assert_not Book.exists?(@book.id), "an unacquired book with no other request goes with it, as on the classic page"
  end

  test "removing with the torrent asks the client to drop every torrent the request had while keeping its files" do
    running = torrent(external_id: "running-hash")
    finished = torrent(status: :failed, external_id: "old-hash")
    sign_in_as(@member)
    withdraw(remove_torrent: true)
    assert_response :success
    assert_equal [ [ "running-hash", false ], [ "old-hash", false ] ], @removed.sort_by { |id, _| id == "running-hash" ? 0 : 1 }
    assert_not Download.exists?(running.id)
    assert_not Download.exists?(finished.id)
  end

  test "a download client that can't be reached still lets the request go, as the classic page does" do
    torrent(external_id: "unreachable-hash")
    sign_in_as(@member)
    withdraw(remove_torrent: true, adapter: unreachable_adapter)
    assert_response :success
    assert_equal [ [ "unreachable-hash", false ] ], @removed
    assert_not Request.exists?(@mine.id)
  end

  test "a book already in the library and another account's request for it are kept" do
    @mine.update!(book: @ebook)
    theirs = Request.create!(book: @ebook, user: @other, status: :pending)
    sign_in_as(@member)
    withdraw
    assert_response :success
    assert Book.exists?(@ebook.id)
    assert File.exist?(@epub_path)
    assert Request.exists?(theirs.id)
  end

  test "a request that finished after the page was read is refused and kept with its library file" do
    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    @mine.update!(book: @ebook, status: :completed, completed_at: Time.current)
    assert_no_difference -> { cancellations } do
      assert_equal({ "error" => "request_changed", "message" => CHANGED }, withdraw(revision: revision, remove_torrent: false))
    end
    assert_response :conflict
    assert @mine.reload.completed?
    assert File.exist?(@epub_path)
  end

  test "a torrent added or a state changed after the page was read is refused before anything is removed" do
    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    download = torrent
    withdraw(revision: revision, remove_torrent: false)
    assert_response :conflict
    assert download.reload.downloading?

    revision = withdrawal.fetch("revision")
    @mine.update!(status: :processing)
    withdraw(revision: revision, remove_torrent: true)
    assert_response :conflict
    assert_empty @removed
    assert @mine.reload.processing?
  end

  test "a direct download that began awaiting recovery after the read is refused instead of stopping the request" do
    download = @mine.downloads.create!(name: "Direct", status: :downloading)
    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    download.update_columns(direct_reservation_token: "reservation")
    assert_no_enqueued_jobs(only: DirectDownloadRecoveryJob) do
      withdraw(revision: revision)
    end
    assert_equal "request_changed", response.parsed_body.fetch("error")
    assert @mine.reload.downloading?
    assert download.reload.downloading?
    sign_in_as(@member)
    assert_nil withdrawal
  end

  test "an upload admitted after the read keeps the request, its download and the torrent, with the model's reason" do
    download = torrent
    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    upload = Upload.create!(user: @member, request: @mine, original_filename: "mine.epub", file_path: File.join(@root, "mine.epub"), status: :pending)
    assert_no_difference -> { cancellations } do
      assert_equal({ "error" => "cannot_remove", "message" => @mine.upload_cancellation_blocked_message }, withdraw(revision: revision, remove_torrent: true))
    end
    assert_response :conflict
    assert_empty @removed
    assert @mine.reload.downloading?
    assert download.reload.downloading?
    assert upload.reload.pending?
  end

  test "an import claimed after the read keeps the request and its download" do
    download = torrent
    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    download.update!(status: :completed, post_processing_job_id: "import-job")
    withdraw(revision: revision, remove_torrent: true)
    assert_response :conflict
    assert_equal @mine.post_processing_recovery_message, response.parsed_body.fetch("message")
    assert_empty @removed
    assert Download.exists?(download.id)
  end

  test "a repeated removal finds nothing, and a removal racing an earlier claim is refused until the page is read again" do
    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    withdraw(revision: revision)
    assert_response :success
    assert_equal({ "error" => "not_found" }, withdraw(revision: revision))
    assert_response :not_found

    request = Request.create!(book: Book.create!(title: "Claimed elsewhere", book_type: :ebook), user: @member, status: :downloading)
    download = torrent(request)
    revision = withdrawal(request).fetch("revision")
    request.claim_destructive_cancellation!
    withdraw(request, revision: revision, remove_torrent: true)
    assert_response :conflict
    assert_empty @removed
    assert Request.exists?(request.id)
    assert_equal({ "id" => request.id.to_s, "status" => "removed" }, withdraw(request, remove_torrent: true).fetch("request"))
    assert_equal [ [ download.external_id, false ] ], @removed
  end

  test "another account's request is not found, and an administrator or a member promoted since the read is sent back to the page" do
    torrent
    sign_in_as(@other)
    withdraw(revision: "0" * 32, user: @other)
    assert_response :not_found

    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    @member.update!(role: :admin)
    assert_equal({ "error" => "request_changed", "message" => CHANGED }, withdraw(revision: revision, remove_torrent: true))
    assert_response :conflict
    sign_in_as(@admin)
    withdraw(revision: revision, user: @admin)
    assert_response :conflict
    assert_empty @removed
    assert @mine.reload.downloading?
  end

  test "the page must name the revision it read and the torrent choice it showed" do
    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    [ { remove_torrent: false }, { expected_revision: revision }, { expected_revision: revision, remove_torrent: "1" }, { expected_revision: [ revision ], remove_torrent: false } ].each do |body|
      post web_preview_api_request_withdraw_path(@mine), params: body, headers: account_headers(@member), as: :json
      assert_response :bad_request
      assert_equal "invalid_request", response.parsed_body.fetch("error")
    end
    withdraw(revision: "not-the-revision")
    assert_response :conflict
    assert Request.exists?(@mine.id)
  end

  test "removal needs the page's CSRF token, the account that read the page, a session and the preview" do
    sign_in_as(@member)
    revision = withdrawal.fetch("revision")
    with_forgery_protection do
      withdraw(revision: revision)
      assert_response :unprocessable_entity
      assert_equal "invalid_csrf", response.parsed_body.fetch("error")
    end
    post web_preview_api_request_withdraw_path(@mine), params: { expected_revision: revision, remove_torrent: false }, headers: account_headers(@other), as: :json
    assert_response :unauthorized
    assert_equal "account_changed", response.parsed_body.fetch("error")
    ENV[WebPreview::Access::VARIABLE] = @admin.id.to_s
    withdraw(revision: revision)
    assert_response :not_found
    ENV[WebPreview::Access::VARIABLE] = nil
    withdraw(revision: revision)
    assert_response :not_found
    ENV[WebPreview::Access::VARIABLE] = @member.id.to_s
    delete session_path
    withdraw(revision: revision)
    assert_response :unauthorized
    assert_equal "signed_out", response.parsed_body.fetch("error")
    assert Request.exists?(@mine.id)
  end

  test "the existing removal and cancel endpoints answer as before" do
    sign_in_as(@member)
    post web_preview_api_request_remove_path(@mine), headers: account_headers(@member), as: :json
    assert_response :conflict
    assert_equal({ "error" => "cannot_remove", "message" => "Only finished requests can be deleted." }, response.parsed_body)
    post web_preview_api_request_cancel_path(@mine), headers: account_headers(@member), as: :json
    assert_response :success
    assert @mine.reload.failed?
    assert Request.exists?(@mine.id)
  end
end
