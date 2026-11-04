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

  def self.call(request, replace_library_file: false)
    new(request, replace_library_file: replace_library_file).call
  end

  def initialize(request, replace_library_file: false)
    @request = request
    @replace_library_file = replace_library_file
    @min_seeders = SettingsService.get(:auto_select_min_seeders, default: 1)
    @confidence_threshold = SettingsService.get(:auto_select_confidence_threshold, default: 90)
    @requested_language = request.effective_language
  end

  def call
    refresh_file_size_scores!
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

    @request.select_result!(best_result, replace_library_file: @replace_library_file)
    log_success(best_result)
    SelectionResult.new(selected: true, reason: :auto_selected, search_result: best_result)
  rescue => e
    Rails.logger.error "[AutoSelectService] Error for request ##{@request.id}: #{e.message}"
    SelectionResult.new(selected: false, reason: :error)
  end

  private

  # Scores are stored at search time. Fallback selection must use the size
  # limits configured now, including a limit that was cleared.
  def refresh_file_size_scores!
    return unless file_size_scores_might_be_stale?

    @request.search_results.pending.not_blocklisted.find_each do |result|
      refresh_file_size_score!(result)
    end
  end

  def file_size_scores_might_be_stale?
    limits = SettingsService.file_size_limits_for(@request.book.book_type)
    return true if limits[:min_bytes] || limits[:max_bytes]

    @request.search_results.pending.not_blocklisted.any? { |result| result.file_size_adjustment.nonzero? }
  end

  def refresh_file_size_score!(result)
    assessment = ReleaseScorer.file_size_assessment(result.size_bytes, @request.book.book_type)
    return if file_size_score_current?(result.score_breakdown, assessment)

    fresh = ReleaseScorer.score(result, @request)
    metadata = preserved_search_metadata(result.score_breakdown)
    penalty = metadata["search_penalty"].to_i
    result.update!(
      detected_language: fresh.detected_languages.first,
      confidence_score: [ fresh.total - penalty, 0 ].max,
      score_breakdown: fresh.breakdown.stringify_keys.merge(metadata)
    )
  end

  def file_size_score_current?(breakdown, assessment)
    breakdown_value(breakdown, "file_size_adjustment").to_i == assessment[:adjustment].to_i &&
      breakdown_value(breakdown, "file_size_status").to_s == assessment[:status].to_s
  end

  def preserved_search_metadata(breakdown)
    return {} unless breakdown.is_a?(Hash)

    %w[search_attempt search_query search_penalty].each_with_object({}) do |key, metadata|
      next unless breakdown.key?(key) || breakdown.key?(key.to_sym)

      metadata[key] = breakdown_value(breakdown, key)
    end
  end

  def breakdown_value(breakdown, key)
    return nil unless breakdown.is_a?(Hash)
    return breakdown[key] if breakdown.key?(key)

    breakdown[key.to_sym] if breakdown.key?(key.to_sym)
  end

  def find_matching_results
    @request.search_results
      .pending
      .not_blocklisted
      .auto_selectable(@confidence_threshold)
      .matches_language(@requested_language)
      .best_first
      .select(&:auto_select_allowed_by_preferences?)
  end

  def meets_confidence_threshold?(result)
    (result.confidence_score || 0) >= @confidence_threshold
  end

  def meets_seeder_threshold?(result)
    return true if result.usenet? || result.direct_download?
    (result.seeders || 0) >= @min_seeders
  end

  def log_success(result)
    Rails.logger.info "[AutoSelectService] Auto-selected '#{result.title}' (score: #{result.confidence_score}) for request ##{@request.id}"
  end

  def log_skip(reason)
    Rails.logger.info "[AutoSelectService] Skipped for request ##{@request.id}: #{reason}"
  end
end
