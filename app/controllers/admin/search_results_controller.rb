# frozen_string_literal: true

module Admin
  class SearchResultsController < BaseController
    before_action :set_request
    before_action :set_search_result, only: [:select]

    def index
      @search_results = @request.search_results.best_first
    end

    def select
      unless @search_result.downloadable?
        redirect_back fallback_location: admin_request_search_results_path(@request),
                      alert: "This result cannot be downloaded (no download link available)"
        return
      end

      begin
        @request.select_result!(@search_result)
        redirect_back fallback_location: requests_path,
                      notice: "Download initiated for: #{@search_result.title}"
      rescue ArgumentError => e
        redirect_back fallback_location: admin_request_search_results_path(@request), alert: e.message
      end
    end

    def refresh
      # Clear existing results and re-queue for search
      @request.search_results.destroy_all
      @request.update!(status: :pending)
      SearchJob.perform_later(@request.id)

      redirect_to request_path(@request),
                  notice: "Search refreshed. Results will appear shortly."
    end

    private

    def set_request
      @request = Request.find(params[:request_id])
    end

    def set_search_result
      @search_result = @request.search_results.find(params[:id])
    end
  end
end
