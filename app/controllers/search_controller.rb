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
    else
      begin
        @results = MetadataService.search(@query)
        @error = nil
      rescue HardcoverClient::ConnectionError, OpenLibraryClient::ConnectionError => e
        @results = []
        @error = "Unable to connect to metadata service. Please try again later."
        Rails.logger.error("Metadata service connection error: #{e.message}")
      rescue HardcoverClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
        @results = []
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
