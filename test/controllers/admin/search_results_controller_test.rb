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
      assert_match(/seeders/, response.body)
    end

    # === Select ===

    test "select creates download and updates statuses" do
      assert_difference -> { Download.count }, 1 do
        post select_admin_request_search_result_path(@request_record, @pending_result)
      end

      @pending_result.reload
      @request_record.reload

      assert @pending_result.selected?
      assert @request_record.downloading?
      # Uses redirect_back with fallback to requests_path
      assert_redirected_to requests_path
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

      assert_enqueued_with(job: SearchJob) do
        post refresh_admin_request_search_results_path(@request_record)
      end

      @request_record.reload
      assert @request_record.pending?
      assert @request_record.search_results.empty?

      assert_redirected_to request_path(@request_record)
      assert_match /refreshed/, flash[:notice]
    end
  end
end
