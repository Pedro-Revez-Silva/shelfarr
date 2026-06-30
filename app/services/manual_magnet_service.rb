# frozen_string_literal: true

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

  class << self
    def call(...)
      new(...).call
    end
  end

  def initialize(request:, magnet_url:)
    @request = request
    @magnet = MagnetLink.parse(magnet_url)
  end

  def call
    return failure("Please provide a magnet link.") if @magnet.url.blank?
    unless @magnet.magnet?
      return failure("That doesn't look like a magnet link. Magnet links start with \"magnet:?\".")
    end
    if @request.completed?
      return failure("This request is already completed. Cancel it before downloading a different release.")
    end

    info_hash = @magnet.info_hash
    if info_hash.blank?
      return failure("Magnet link has no valid torrent hash (expected xt=urn:btih: with a 40-char hex or 32-char base32 hash).")
    end

    search_result = build_search_result(info_hash)
    download = @request.select_result!(search_result)

    Result.new(search_result: search_result, download: download, error: nil)
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    failure("Could not add magnet link: #{e.message}")
  end

  private

  def build_search_result(info_hash)
    guid = "manual:#{info_hash}"
    search_result = @request.search_results.find_or_initialize_by(guid: guid)
    search_result.assign_attributes(
      title: @magnet.display_name || @request.book.title,
      indexer: "Manual",
      source: SearchResult::SOURCE_MANUAL,
      magnet_url: @magnet.url,
      download_url: nil,
      status: :pending
    )
    search_result.save!
    search_result.calculate_score!
    search_result
  end

  def failure(message)
    Result.new(search_result: nil, download: nil, error: message)
  end
end
