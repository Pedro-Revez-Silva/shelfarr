# frozen_string_literal: true

require "test_helper"

class AcquiredLibraryRedownloadTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
    SettingsService.set(:gutenberg_enabled, true)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")
    SettingsService.set(:auto_select_enabled, false)
    GutenbergClient.reset_connection! if defined?(GutenbergClient)
  end

  teardown do
    SettingsService.set(:gutenberg_enabled, false)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")
    SettingsService.set(:auto_select_enabled, false)
    GutenbergClient.reset_connection! if defined?(GutenbergClient)
  end

  test "a failed direct redownload of an acquired title can be cancelled and the library copy removed" do
    Dir.mktmpdir do |dir|
      SettingsService.set(:ebook_output_path, dir)
      book = Book.create!(
        title: "Pride and Prejudice",
        author: "Austen, Jane",
        book_type: :ebook
      )
      request = Request.create!(book: book, user: users(:one), status: :downloading)
      original = request.search_results.create!(
        guid: "gutenberg:1342",
        title: "Pride and Prejudice - Austen, Jane [EPUB]",
        indexer: "Project Gutenberg",
        source: SearchResult::SOURCE_GUTENBERG,
        download_url: "https://www.gutenberg.org/ebooks/1342.epub3.images?download=1",
        status: :selected
      )
      original_download = request.downloads.create!(
        name: original.title,
        search_result: original,
        status: :queued
      )

      VCR.turned_off do
        stub_request(:get, "https://www.gutenberg.org/ebooks/1342.epub3.images")
          .with(query: hash_including("download" => "1"))
          .to_return(
            status: 200,
            body: "PK\x03\x04" + ("x" * 1024),
            headers: { "Content-Type" => "application/epub+zip" }
          )

        DownloadJob.perform_now(original_download.id)
      end

      request.reload
      book.reload
      original_download.reload
      assert request.completed?, request.issue_description
      assert book.acquired?
      library_bytes = File.binread(original_download.download_path)
      assert_recovery_clear(original_download, "completed direct download")

      original_download.update!(post_processing_job_id: "legacy-success-owner")
      assert_not request.post_processing_recovery_pending?
      assert_not book.post_processing_recovery_pending?

      replacement = request.search_results.create!(
        guid: "gutenberg:1342:pdf",
        title: "Pride and Prejudice - Austen, Jane [PDF]",
        indexer: "Project Gutenberg",
        source: SearchResult::SOURCE_GUTENBERG,
        download_url: "https://www.gutenberg.org/ebooks/1342.pdf.images?download=1",
        status: :pending
      )

      post select_admin_request_search_result_path(request, replacement)
      assert_redirected_to requests_path
      follow_redirect!
      replacement_download = request.downloads.order(:id).last
      assert replacement_download.queued?

      DownloadJob.perform_now(replacement_download.id)

      request.reload
      replacement_download.reload
      book.reload
      original_download.reload
      assert replacement_download.failed?, replacement_download.status
      assert request.attention_needed?
      assert_includes request.issue_description, "existing file was preserved"
      assert book.acquired?
      assert_equal library_bytes, File.binread(original_download.download_path)
      assert_recovery_clear(replacement_download, "failed redownload")

      state = deadlock_state(request, book)
      assert request.can_be_cancelled?, state
      assert request.can_retry?, state
      assert_not request.direct_acquisition_recovery_pending?, state
      assert_not request.post_processing_recovery_pending?, state
      assert_not book.post_processing_recovery_pending?, state
      assert request.not_found?, state

      get request_path(request)
      assert_response :success
      assert_select "button", text: "Cancel Request"

      delete library_path(book), params: { delete_files: "1" }
      assert_redirected_to library_index_path, "#{state} alert=#{flash[:alert].inspect}"
      assert_match(/removed from the library/, flash[:notice].to_s)
      assert_not Book.exists?(book.id)
      assert_not File.exist?(original_download.download_path)
    end
  end

  private

  def assert_recovery_clear(download, label)
    present = Request::DIRECT_RECOVERY_COLUMNS.select { |column| download.public_send(column).present? }
    assert_empty present, "#{label} still has #{present.inspect}"
  end

  def deadlock_state(request, book)
    downloads = request.downloads.map do |download|
      {
        id: download.id,
        status: download.status,
        type: download.download_type,
        job: download.post_processing_job_id,
        cleanup: download.post_processing_cleanup_state
      }
    end
    "status=#{request.status} attention=#{request.attention_needed?} " \
      "issue=#{request.issue_description.inspect} " \
      "direct=#{request.direct_acquisition_recovery_pending?} " \
      "post=#{request.post_processing_recovery_pending?} " \
      "upload=#{request.upload_cancellation_blocked?} " \
      "book_post=#{book.post_processing_recovery_pending?} " \
      "owned=#{book.owned_media_recovery_pending?} " \
      "downloads=#{downloads.inspect}"
  end
end
