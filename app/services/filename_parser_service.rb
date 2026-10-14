# frozen_string_literal: true

class FilenameParserService
  Result = Data.define(:title, :author, :confidence, :pattern_matched)

  # Patterns ordered by specificity (most specific first)
  PATTERNS = [
    # "Author Name - Book Title" (common for audiobooks)
    {
      regex: /\A(.+?)\s*[-–—]\s*(.+)\z/,
      author_group: 1,
      title_group: 2,
      name: :author_dash_title
    },
    # "Book Title (Author Name)"
    {
      regex: /\A(.+?)\s*\(([^)]+)\)\z/,
      author_group: 2,
      title_group: 1,
      name: :title_paren_author
    },
    # "Book Title [Author Name]"
    {
      regex: /\A(.+?)\s*\[([^\]]+)\]\z/,
      author_group: 2,
      title_group: 1,
      name: :title_bracket_author
    },
    # "Author_Name-Book_Title" (underscores as spaces)
    {
      regex: /\A([^-]+)[-](.+)\z/,
      author_group: 1,
      title_group: 2,
      name: :underscore_separated,
      transform: ->(s) { s.tr("_", " ") }
    }
  ].freeze

  class << self
    def parse(filename)
      basename = File.basename(filename, File.extname(filename))

      # Clean up common artifacts
      basename = clean_filename(basename)

      PATTERNS.each do |pattern|
        result = try_pattern(basename, pattern)
        return result if result
      end

      # Fallback: use entire basename as title, no author
      Result.new(
        title: normalize_text(basename),
        author: nil,
        confidence: 20,
        pattern_matched: :fallback
      )
    end

    private

    def try_pattern(basename, pattern)
      match = basename.match(pattern[:regex])
      return nil unless match

      raw_author = match[pattern[:author_group]]
      raw_title = match[pattern[:title_group]]

      if pattern[:transform]
        raw_author = pattern[:transform].call(raw_author)
        raw_title = pattern[:transform].call(raw_title)
      end

      author = normalize_text(raw_author)
      title = normalize_text(raw_title)

      return nil if title.blank? || title.length < 2

      confidence = calculate_confidence(title, author, pattern[:name])

      Result.new(
        title: title,
        author: author.presence,
        confidence: confidence,
        pattern_matched: pattern[:name]
      )
    end

    def clean_filename(basename)
      basename
        .gsub(/\s*\(\d{4}\)\s*/, " ")
        .gsub(/\s*\[\d{4}\]\s*/, " ")
        .gsub(/\s*-\s*(?:Unabridged|Abridged)\s*/i, " ")
        .gsub(/\s*(?:MP3|M4B|EPUB|PDF|MOBI)\s*/i, " ")
        .gsub(/\s+/, " ")                                  # Collapse whitespace
        .strip
    end

    def normalize_text(text)
      text
        .strip
        .gsub(/\s+/, " ")      # Collapse whitespace
        .gsub(/[_]+/, " ")     # Underscores to spaces
        .split(" ")
        .map(&:capitalize)     # Title case
        .join(" ")
    end

    def calculate_confidence(title, author, pattern_name)
      base_confidence = case pattern_name
      when :author_dash_title then 80
      when :title_paren_author then 75
      when :title_bracket_author then 70
      when :underscore_separated then 60
      else 50
      end

      # Boost confidence if we have both title and author
      base_confidence += 10 if author.present?

      # Reduce confidence for very short titles
      base_confidence -= 20 if title.length < 5

      # Reduce confidence for very long titles (might be multiple books)
      base_confidence -= 10 if title.length > 100

      base_confidence.clamp(0, 100)
    end
  end
end
