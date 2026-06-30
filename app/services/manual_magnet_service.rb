# frozen_string_literal: true

require "uri"

# Creates a search result from an admin-supplied magnet link and sends it
# through the normal selection/download pipeline (torrent client dispatch,
# monitoring and post-processing). Useful for sources that can't be wired up
# to an indexer, e.g. AudiobookBay magnets pasted by hand.
class ManualMagnetService
  Result = Data.define(:search_result, :download, :error) do
    def success?
      error.nil?
    end
  end

  # magnet:?xt=urn:btih:<40-hex or 32-base32 hash>
  INFO_HASH_REGEX = /xt=urn:btih:([a-z0-9]+)/i

  class << self
    def call(...)
      new(...).call
    end
  end

  def initialize(request:, magnet_url:)
    @request = request
    @magnet_url = magnet_url.to_s.strip
  end

  def call
    return failure("Please provide a magnet link.") if @magnet_url.blank?
    unless @magnet_url.downcase.start_with?("magnet:?")
      return failure("That doesn't look like a magnet link. Magnet links start with \"magnet:?\".")
    end

    info_hash = extract_info_hash
    return failure("Magnet link is missing a torrent hash (xt=urn:btih:...).") if info_hash.blank?

    search_result = build_search_result(info_hash)
    download = @request.select_result!(search_result)

    Result.new(search_result: search_result, download: download, error: nil)
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    failure("Could not add magnet link: #{e.message}")
  end

  private

  def build_search_result(info_hash)
    guid = "manual:#{info_hash.downcase}"
    search_result = @request.search_results.find_or_initialize_by(guid: guid)
    search_result.assign_attributes(
      title: magnet_title,
      indexer: "Manual",
      source: SearchResult::SOURCE_PROWLARR,
      magnet_url: @magnet_url,
      download_url: nil,
      status: :pending
    )
    search_result.save!
    search_result.calculate_score!
    search_result
  end

  def magnet_title
    magnet_params["dn"].presence || @request.book.title
  end

  def extract_info_hash
    match = @magnet_url.match(INFO_HASH_REGEX)
    match && match[1]
  end

  def magnet_params
    query = @magnet_url.split("?", 2)[1].to_s
    URI.decode_www_form(query).to_h
  rescue ArgumentError
    {}
  end

  def failure(message)
    Result.new(search_result: nil, download: nil, error: message)
  end
end
