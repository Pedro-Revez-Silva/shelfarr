# frozen_string_literal: true

require "test_helper"

module Admin
  class SearchResultsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = users(:two)
      @user = users(:one)
      @request_record = requests(:pending_request)
      @pending_result = search_results(:pending_result)
      @selected_result = search_results(:selected_result)
      @no_link_result = search_results(:no_link_result)

      sign_in_as(@admin)
    end

    # === Authorization ===

    test "index requires admin" do
      sign_out
      sign_in_as(@user)

      get admin_request_search_results_path(@request_record)
      assert_redirected_to root_path
    end

    test "select requires admin" do
      sign_out
      sign_in_as(@user)

      post select_admin_request_search_result_path(@request_record, @pending_result)
      assert_redirected_to root_path
    end

    test "refresh requires admin" do
      sign_out
      sign_in_as(@user)

      post refresh_admin_request_search_results_path(@request_record)
      assert_redirected_to root_path
    end

    # === Index ===

    test "index shows search results" do
      get admin_request_search_results_path(@request_record)
      assert_response :success

      assert_select "h2", /Search Results for/
      assert_select "p", /#{@pending_result.title}/
    end

    test "index shows empty state when no results" do
      @request_record.search_results.destroy_all

      get admin_request_search_results_path(@request_record)
      assert_response :success

      assert_select "h3", "No search results"
    end

    test "index shows result details" do
      get admin_request_search_results_path(@request_record)
      assert_response :success

      assert_match @pending_result.indexer, response.body
      assert_match(/seeds/, response.body)
    end

    test "index allows selecting rejected downloadable results" do
      @pending_result.update!(status: :rejected)

      get admin_request_search_results_path(@request_record)
      assert_response :success

      assert_select "form[action='#{select_admin_request_search_result_path(@request_record, @pending_result)}']" do
        assert_select "button", text: "Select Instead"
      end
    end

    test "index labels blocklisted results and offers retry anyway" do
      blocklisted = search_results(:blocklisted_result)

      get admin_request_search_results_path(@request_record)
      assert_response :success

      assert_select "span[title='#{blocklisted.blocklist_reason}']", text: "Blocklisted"
      assert_select "form[action='#{select_admin_request_search_result_path(@request_record, blocklisted)}']" do
        assert_select "button", text: "Retry Anyway"
      end
    end

    # === Select ===

    test "select creates download and updates statuses" do
      assert_difference -> { Download.count }, 1 do
        post select_admin_request_search_result_path(@request_record, @pending_result),
          headers: { "HTTP_REFERER" => "http://[malformed" }
      end

      @pending_result.reload
      @request_record.reload
      download = @request_record.downloads.order(:created_at).last

      assert @pending_result.selected?
      assert @request_record.downloading?
      assert_equal @pending_result, download.search_result
      # Uses redirect_back with fallback to requests_path
      assert_redirected_to requests_path
    end

    test "select can override a rejected result" do
      @pending_result.update!(status: :rejected)

      assert_difference -> { Download.count }, 1 do
        post select_admin_request_search_result_path(@request_record, @pending_result)
      end

      assert @pending_result.reload.selected?
      assert @selected_result.reload.rejected?
    end

    test "selecting a blocklisted result clears blocklist and starts download" do
      blocklisted = search_results(:blocklisted_result)

      assert_difference -> { Download.count }, 1 do
        post select_admin_request_search_result_path(@request_record, blocklisted)
      end

      assert blocklisted.reload.selected?
      assert_not blocklisted.blocklisted?
      assert_nil blocklisted.blocklist_reason
    end

    test "select marks other results as rejected" do
      post select_admin_request_search_result_path(@request_record, @pending_result)

      # Reload all results
      @selected_result.reload
      @no_link_result.reload

      # The previously selected result should be changed to rejected
      # Note: selected_result was already :selected in fixture, so it becomes :rejected
      assert @selected_result.rejected?
    end

    test "select rejects result without download link" do
      post select_admin_request_search_result_path(@request_record, @no_link_result)

      assert_redirected_to admin_request_search_results_path(@request_record)
      assert_match /cannot be downloaded/, flash[:alert]

      @no_link_result.reload
      assert @no_link_result.pending? # Status unchanged
    end

    test "select enqueues download job" do
      assert_enqueued_with(job: DownloadJob) do
        post select_admin_request_search_result_path(@request_record, @pending_result)
      end
    end

    # === Refresh ===

    test "refresh clears results and requeues search" do
      assert @request_record.search_results.any?
      previous_generation = @request_record.search_generation
      @request_record.store_offers.create!(
        provider: "ebooks_com",
        external_id: "refresh-offer",
        title: "The Pending Ebook",
        formats: [ "epub" ],
        market: "PT",
        drm_free: true,
        storefront_url: "https://www.ebooks.com/en-pt/book/refresh-offer/the-pending-ebook/"
      )

      assert_enqueued_with(job: SearchJob, args: [ @request_record.id ]) do
        post refresh_admin_request_search_results_path(@request_record),
          headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }
      end

      @request_record.reload
      assert @request_record.pending?
      assert_equal previous_generation + 1, @request_record.search_generation
      assert @request_record.search_results.empty?
      assert @request_record.store_offers.empty?

      assert_redirected_to request_path(@request_record)
      assert_match /refreshed/, flash[:notice]
    end

    test "refresh preserves manual download results" do
      manual_magnet = @request_record.search_results.create!(
        guid: "manual-magnet:#{'a' * 40}",
        title: "Manual magnet result",
        magnet_url: "magnet:?xt=urn:btih:#{'a' * 40}",
        source: SearchResult::SOURCE_MANUAL_MAGNET,
        indexer: "Manual Magnet",
        status: :selected
      )
      manual_nzb = @request_record.search_results.create!(
        guid: "manual-nzb:#{'b' * 64}",
        title: "Manual NZB result",
        download_url: "https://downloads.example/book.nzb",
        seeders: nil,
        source: SearchResult::SOURCE_MANUAL_NZB,
        indexer: "Manual NZB",
        status: :selected
      )

      post refresh_admin_request_search_results_path(@request_record)

      @request_record.reload
      assert_equal [ manual_magnet, manual_nzb ], @request_record.search_results.order(:id).to_a
    end
  end
end
