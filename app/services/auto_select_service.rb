# frozen_string_literal: true

class AutoSelectService
  class SelectionResult
    attr_reader :selected, :reason, :search_result

    def initialize(selected:, reason:, search_result: nil)
      @selected = selected
      @reason = reason
      @search_result = search_result
    end

    def success?
      @selected
    end
  end

  def self.call(request)
    new(request).call
  end

  def initialize(request)
    @request = request
    @min_seeders = SettingsService.get(:auto_select_min_seeders, default: 1)
    @confidence_threshold = SettingsService.get(:auto_select_confidence_threshold, default: 90)
    @requested_language = request.effective_language
  end

  def call
    matching_results = find_matching_results
    candidates = matching_results.select(&:downloadable?)

    if matching_results.empty?
      log_skip("no results meeting criteria (confidence >= #{@confidence_threshold}, language: #{@requested_language})")
      return SelectionResult.new(selected: false, reason: :no_matching_results)
    end

    if candidates.empty?
      log_skip("#{matching_results.size} results match criteria but none are downloadable")
      return SelectionResult.new(selected: false, reason: :no_downloadable_results)
    end

    best_result = candidates.first

    unless meets_confidence_threshold?(best_result)
      log_skip("best result score #{best_result.confidence_score || 0} below threshold #{@confidence_threshold}")
      return SelectionResult.new(selected: false, reason: :below_confidence_threshold, search_result: best_result)
    end

    unless meets_seeder_threshold?(best_result)
      log_skip("best result has #{best_result.seeders || 0} seeders, minimum is #{@min_seeders}")
      return SelectionResult.new(selected: false, reason: :below_seeder_threshold, search_result: best_result)
    end

    @request.select_result!(best_result)
    log_success(best_result)
    SelectionResult.new(selected: true, reason: :auto_selected, search_result: best_result)
  rescue => e
    Rails.logger.error "[AutoSelectService] Error for request ##{@request.id}: #{e.message}"
    SelectionResult.new(selected: false, reason: :error)
  end

  private

  def find_matching_results
    @request.search_results
      .pending
      .auto_selectable(@confidence_threshold)
      .matches_language(@requested_language)
      .best_first
  end

  def meets_confidence_threshold?(result)
    (result.confidence_score || 0) >= @confidence_threshold
  end

  def meets_seeder_threshold?(result)
    return true if result.usenet?
    (result.seeders || 0) >= @min_seeders
  end

  def log_success(result)
    Rails.logger.info "[AutoSelectService] Auto-selected '#{result.title}' (score: #{result.confidence_score}) for request ##{@request.id}"
  end

  def log_skip(reason)
    Rails.logger.info "[AutoSelectService] Skipped for request ##{@request.id}: #{reason}"
  end
end
