# frozen_string_literal: true

# Scores search results based on how well they match a request.
# Returns a confidence score (0-100) with a detailed breakdown.
class ReleaseScorer
  # Weight configuration for each scoring factor
  WEIGHTS = {
    title: 40,      # How well does the release title match the book title?
    author: 20,     # Is the author name present in the release title?
    language: 25,   # Does it match the requested language?
    format: 10,     # Does the format (audiobook/ebook) match?
    health: 5       # Seeders/availability (for torrents)
  }.freeze

  Result = Data.define(:total, :breakdown, :detected_languages, :detected_format) do
    def high_confidence?
      total >= 90
    end

    def medium_confidence?
      total >= 70 && total < 90
    end

    def low_confidence?
      total < 70
    end
  end

  def initialize(search_result, request)
    @search_result = search_result
    @request = request
    @book = request.book
    @parsed = ReleaseParserService.parse(search_result.title)
  end

  # Calculate the confidence score
  # @return [Result] Score result with total, breakdown, and detected metadata
  def score
    breakdown = {
      title: calculate_title_score,
      author: calculate_author_score,
      language: calculate_language_score,
      format: calculate_format_score,
      health: calculate_health_score
    }

    # Calculate weighted total
    total = WEIGHTS.sum do |key, weight|
      (breakdown[key] * weight) / 100.0
    end.round

    Result.new(
      total: total,
      breakdown: breakdown,
      detected_languages: @parsed[:languages],
      detected_format: @parsed[:format]
    )
  end

  class << self
    # Score a search result against a request
    # @param search_result [SearchResult] The search result to score
    # @param request [Request] The request to match against
    # @return [Result] Score result
    def score(search_result, request)
      new(search_result, request).score
    end
  end

  private

  # Title matching score (0-100)
  # Uses trigram similarity like BookMatcherService
  def calculate_title_score
    release_title = normalize_for_matching(@search_result.title)
    book_title = normalize_for_matching(@book.title)

    return 0 if release_title.blank? || book_title.blank?

    # Check if book title appears in release title
    if release_title.include?(book_title)
      100
    else
      trigram_similarity(release_title, book_title)
    end
  end

  # Author matching score (0-100)
  # Checks if author name appears in release title
  def calculate_author_score
    return 50 if @book.author.blank?  # Neutral if no author to match

    release_title = normalize_for_matching(@search_result.title)
    author = normalize_for_matching(@book.author)

    return 0 if release_title.blank?

    # Check for full author name
    return 100 if release_title.include?(author)

    # Check for last name (common pattern)
    author_parts = author.split
    if author_parts.length > 1
      last_name = author_parts.last
      return 80 if release_title.include?(last_name) && last_name.length > 3
    end

    # Check for first name (less reliable)
    first_name = author_parts.first
    return 40 if release_title.include?(first_name) && first_name.length > 3

    0
  end

  # Language matching score (0-100)
  # 100 = matches requested, 50 = unknown/multi, 0 = wrong language
  def calculate_language_score
    requested_language = @request.language || SettingsService.get(:default_language)
    detected = @parsed[:languages]

    # Multi-language releases match any language
    return 100 if @parsed[:is_multi_language]

    # No language detected - treat as neutral (might match, might not)
    return 50 if detected.empty?

    # Check if requested language is in detected languages
    return 100 if detected.include?(requested_language)

    # Wrong language detected
    0
  end

  # Format matching score (0-100)
  # Checks if release format matches book type
  def calculate_format_score
    detected = @parsed[:format]
    requested = @book.book_type&.to_sym

    # No format detected - neutral
    return 50 if detected.nil?

    # Match check
    case requested
    when :audiobook
      detected == :audiobook ? 100 : 0
    when :ebook
      detected == :ebook ? 100 : 0
    else
      50  # Unknown book type
    end
  end

  # Health/availability score (0-100)
  # Based on seeders for torrents, always 100 for usenet
  def calculate_health_score
    # Usenet always has full availability
    return 100 if usenet?

    seeders = @search_result.seeders || 0

    # Normalize seeders to 0-100 scale
    # 0 seeders = 0, 1-5 = 20-60, 5-20 = 60-80, 20+ = 80-100
    case seeders
    when 0
      0
    when 1..5
      20 + (seeders * 8)
    when 6..20
      60 + ((seeders - 5) * 1.3).round
    else
      [ 80 + ((seeders - 20) * 0.2).round, 100 ].min
    end
  end

  def usenet?
    # Usenet results typically have download_url but no magnet and no seeders
    @search_result.download_url.present? &&
      @search_result.magnet_url.blank? &&
      @search_result.seeders.nil?
  end

  # Normalize text for matching
  def normalize_for_matching(text)
    return "" if text.blank?

    text
      .downcase
      .gsub(/[^a-z0-9\s]/, "")  # Remove special characters
      .gsub(/\s+/, " ")         # Collapse whitespace
      .strip
  end

  # Trigram-based similarity score (0-100)
  def trigram_similarity(str1, str2)
    return 100 if str1 == str2
    return 0 if str1.blank? || str2.blank?

    trigrams1 = to_trigrams(str1)
    trigrams2 = to_trigrams(str2)

    return 0 if trigrams1.empty? || trigrams2.empty?

    intersection = (trigrams1 & trigrams2).size
    union = (trigrams1 | trigrams2).size

    ((intersection.to_f / union) * 100).round
  end

  def to_trigrams(str)
    padded = "  #{str}  "
    (0..padded.length - 3).map { |i| padded[i, 3] }.to_set
  end
end
