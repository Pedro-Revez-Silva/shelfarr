# frozen_string_literal: true

class SearchController < ApplicationController
  def index
    @query = params[:q]
  end

  def results
    @query = params[:q].to_s.strip

    if @query.blank?
      @results = []
      @error = nil
      @audiobookshelf_matches = []
    else
      begin
        @results = MetadataService.search(@query)
        @audiobookshelf_matches = if LibraryItem.exists?
          AudiobookshelfLibraryMatcherService.matches_for_many(@results, limit_per_result: 2)
        else
          Array.new(@results.size) { [] }
        end
        @error = nil
      rescue HardcoverClient::ConnectionError, OpenLibraryClient::ConnectionError => e
        @results = []
        @audiobookshelf_matches = []
        @error = "Unable to connect to metadata service. Please try again later."
        Rails.logger.error("Metadata service connection error: #{e.message}")
      rescue HardcoverClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
        @results = []
        @audiobookshelf_matches = []
        @error = "Search failed. Please try again."
        Rails.logger.error("Metadata service error: #{e.message}")
      end
    end

    respond_to do |format|
      format.turbo_stream
      format.html { render :index }
    end
  end
end
