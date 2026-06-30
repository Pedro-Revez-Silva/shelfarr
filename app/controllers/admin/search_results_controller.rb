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
      # Clear existing search-sourced results and re-queue; keep manually-added
      # results (e.g. admin-pasted magnets) so a refresh doesn't discard them.
      @request.search_results.from_search.destroy_all
      @request.update!(status: :pending)
      SearchJob.perform_later(@request.id)

      redirect_to request_path(@request),
                  notice: "Search refreshed. Results will appear shortly."
    end

    def add_magnet
      result = ManualMagnetService.call(request: @request, magnet_url: params[:magnet_url])

      if result.success?
        redirect_back fallback_location: request_path(@request),
                      notice: "Magnet link added. \"#{result.search_result.title}\" is now downloading."
      else
        redirect_back fallback_location: request_path(@request), alert: result.error
      end
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
