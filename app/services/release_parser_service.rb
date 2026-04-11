# frozen_string_literal: true

# Service for parsing release titles to extract metadata like language, format, and quality.
# Based on patterns from Radarr/Sonarr LanguageParser and rank-torrent-name (RTN).
class ReleaseParserService
  # Supported languages with their ISO 639-1 codes and display names
  LANGUAGES = {
    "en" => { name: "English", flag: "GB" },
    "nl" => { name: "Dutch", flag: "NL" },
    "de" => { name: "German", flag: "DE" },
    "fr" => { name: "French", flag: "FR" },
    "es" => { name: "Spanish", flag: "ES" },
    "it" => { name: "Italian", flag: "IT" },
    "pt" => { name: "Portuguese", flag: "PT" },
    "pt-BR" => { name: "Portuguese (Brazil)", flag: "BR" },
    "ru" => { name: "Russian", flag: "RU" },
    "ja" => { name: "Japanese", flag: "JP" },
    "ko" => { name: "Korean", flag: "KR" },
    "zh" => { name: "Chinese", flag: "CN" },
    "pl" => { name: "Polish", flag: "PL" },
    "sv" => { name: "Swedish", flag: "SE" },
    "da" => { name: "Danish", flag: "DK" },
    "no" => { name: "Norwegian", flag: "NO" },
    "fi" => { name: "Finnish", flag: "FI" },
    "tr" => { name: "Turkish", flag: "TR" },
    "ar" => { name: "Arabic", flag: "SA" },
    "he" => { name: "Hebrew", flag: "IL" },
    "hi" => { name: "Hindi", flag: "IN" },
    "th" => { name: "Thai", flag: "TH" },
    "vi" => { name: "Vietnamese", flag: "VN" },
    "cs" => { name: "Czech", flag: "CZ" },
    "hu" => { name: "Hungarian", flag: "HU" },
    "ro" => { name: "Romanian", flag: "RO" },
    "bg" => { name: "Bulgarian", flag: "BG" },
    "uk" => { name: "Ukrainian", flag: "UA" },
    "el" => { name: "Greek", flag: "GR" }
  }.freeze

  # Language detection patterns - order matters for specificity
  # More specific patterns should come before generic ones
  LANGUAGE_PATTERNS = [
    # English
    { code: "en", pattern: /\benglish\b/i },
    { code: "en", pattern: /(?<![a-z])eng(?![a-z])/i },
    { code: "en", pattern: /(?<![a-z])EN(?![a-z])/ },

    # Dutch/Flemish
    { code: "nl", pattern: /\bdutch\b/i },
    { code: "nl", pattern: /\bflemish\b/i },
    { code: "nl", pattern: /(?<![a-z])NL(?![a-z])/ },
    { code: "nl", pattern: /\.NL\./i },
    { code: "nl", pattern: /\[Dutch\]/i },
    { code: "nl", pattern: /\(Dutch\)/i },

    # German (including Swiss German)
    { code: "de", pattern: /\bgerman\b/i },
    { code: "de", pattern: /\bswissgerman\b/i },
    { code: "de", pattern: /\bger\.dub\b/i },
    { code: "de", pattern: /\bvideomann\b/i },
    { code: "de", pattern: /(?<![a-z])ger(?![a-z])/i },
    { code: "de", pattern: /(?<![a-z])DE(?![a-z])/ },
    { code: "de", pattern: /\.DE\./i },

    # French
    { code: "fr", pattern: /\bfrench\b/i },
    { code: "fr", pattern: /\btruefrench\b/i },
    { code: "fr", pattern: /(?<![a-z])VF(?![a-z])/i },
    { code: "fr", pattern: /(?<![a-z])VFF(?![a-z])/i },
    { code: "fr", pattern: /(?<![a-z])VFQ(?![a-z])/i },
    { code: "fr", pattern: /(?<![a-z])VFI(?![a-z])/i },
    { code: "fr", pattern: /(?<![a-z])FR(?![a-z])/ },
    { code: "fr", pattern: /\.FR\./i },

    # Spanish
    { code: "es", pattern: /\bspanish\b/i },
    { code: "es", pattern: /\bespañol\b/i },
    { code: "es", pattern: /\bcastellano\b/i },
    { code: "es", pattern: /(?<![a-z])ES(?![a-z])/ },
    { code: "es", pattern: /\.ES\./i },
    { code: "es", pattern: /\blatino\b/i },

    # Italian
    { code: "it", pattern: /\bitalian\b/i },
    { code: "it", pattern: /(?<![a-z])ita(?![a-z])/i },
    { code: "it", pattern: /(?<![a-z])IT(?![a-z])/ },
    { code: "it", pattern: /\.IT\./i },

    # Portuguese
    { code: "pt", pattern: /\bportuguese\b/i },
    { code: "pt", pattern: /(?<![a-z])por(?![a-z])/i },
    { code: "pt", pattern: /(?<![a-z])PT(?![a-z])/ },
    { code: "pt", pattern: /\.PT\./i },

    # Portuguese (Brazil)
    { code: "pt-BR", pattern: /\bbrazilian\b/i },
    { code: "pt-BR", pattern: /\bdublado\b/i },
    { code: "pt-BR", pattern: /\bpt-br\b/i },
    { code: "pt-BR", pattern: /\.BR\./i },

    # Russian
    { code: "ru", pattern: /\brussian\b/i },
    { code: "ru", pattern: /(?<![a-z])rus(?![a-z])/i },
    { code: "ru", pattern: /(?<![a-z])RU(?![a-z])/ },

    # Japanese
    { code: "ja", pattern: /\bjapanese\b/i },
    { code: "ja", pattern: /(?<![a-z])jap(?![a-z])/i },
    { code: "ja", pattern: /(?<![a-z])jpn(?![a-z])/i },
    { code: "ja", pattern: /\(JA\)/i },

    # Korean
    { code: "ko", pattern: /\bkorean\b/i },
    { code: "ko", pattern: /(?<![a-z])kor(?![a-z])/i },

    # Chinese
    { code: "zh", pattern: /\bchinese\b/i },
    { code: "zh", pattern: /\bmandarin\b/i },
    { code: "zh", pattern: /\bcantonese\b/i },
    { code: "zh", pattern: /\[CHT\]/i },
    { code: "zh", pattern: /\[CHS\]/i },
    { code: "zh", pattern: /\[BIG5\]/i },
    { code: "zh", pattern: /\[GB\]/i },

    # Polish
    { code: "pl", pattern: /\bpolish\b/i },
    { code: "pl", pattern: /(?<![a-z])PL(?![a-z])/ },
    { code: "pl", pattern: /\bpl\.dub\b/i },
    { code: "pl", pattern: /\bdub\.pl\b/i },

    # Swedish
    { code: "sv", pattern: /\bswedish\b/i },
    { code: "sv", pattern: /(?<![a-z])swe(?![a-z])/i },

    # Danish
    { code: "da", pattern: /\bdanish\b/i },
    { code: "da", pattern: /(?<![a-z])dan(?![a-z])/i },

    # Norwegian
    { code: "no", pattern: /\bnorwegian\b/i },
    { code: "no", pattern: /(?<![a-z])nor(?![a-z])/i },

    # Finnish
    { code: "fi", pattern: /\bfinnish\b/i },
    { code: "fi", pattern: /(?<![a-z])fin(?![a-z])/i },

    # Turkish
    { code: "tr", pattern: /\bturkish\b/i },
    { code: "tr", pattern: /(?<![a-z])tur(?![a-z])/i },

    # Arabic
    { code: "ar", pattern: /\barabic\b/i },

    # Hebrew
    { code: "he", pattern: /\bhebrew\b/i },
    { code: "he", pattern: /\bhebdub\b/i },

    # Hindi
    { code: "hi", pattern: /\bhindi\b/i },

    # Thai
    { code: "th", pattern: /\bthai\b/i },

    # Vietnamese
    { code: "vi", pattern: /\bvietnamese\b/i },
    { code: "vi", pattern: /(?<![a-z])VIE(?![a-z])/i },

    # Czech
    { code: "cs", pattern: /\bczech\b/i },
    { code: "cs", pattern: /(?<![a-z])CZ(?![a-z])/ },

    # Hungarian
    { code: "hu", pattern: /\bhungarian\b/i },
    { code: "hu", pattern: /\bhundub\b/i },
    { code: "hu", pattern: /(?<![a-z])HUN(?![a-z])/i },

    # Romanian
    { code: "ro", pattern: /\bromanian\b/i },
    { code: "ro", pattern: /\brodubbed\b/i },

    # Bulgarian
    { code: "bg", pattern: /\bbulgarian\b/i },
    { code: "bg", pattern: /\bbgaudio\b/i },
    { code: "bg", pattern: /(?<![a-z])BG(?![a-z])/ },

    # Ukrainian
    { code: "uk", pattern: /\bukrainian\b/i },
    { code: "uk", pattern: /(?<![a-z])ukr(?![a-z])/i },

    # Greek
    { code: "el", pattern: /\bgreek\b/i }
  ].freeze

  # Multi-language indicators (treat as matching any requested language)
  MULTI_LANGUAGE_PATTERNS = [
    /\bmulti\b/i,
    /\bdual\b/i,
    /\btri-audio\b/i,
    /\bquad[\.\s]audio\b/i,
    # German dual-language tag (DL but not WEB-DL)
    /(?<!WEB)(?<!WEB-)(?<!WEB\.)(?<!WEB_)\bDL\b/,
    # German multi-language tag
    /\bML\b/
  ].freeze

  # Audiobook format indicators
  AUDIOBOOK_PATTERNS = [
    /\baudiobook\b/i,
    /\bm4b\b/i,
    /\bunabridged\b/i,
    /\babridged\b/i,
    /\bnarrated\s+by\b/i,
    /\bread\s+by\b/i,
    /\b(?:64|128|192|256|320)kbps\b/i,
    /\bmp3\b.*\b(?:audiobook|book)\b/i
  ].freeze

  # Ebook format indicators
  EBOOK_PATTERNS = [
    /\bebook\b/i,
    /\bepub\b/i,
    /\bmobi\b/i,
    /\bazw3?\b/i,
    /\bpdf\b/i,
    /\bcbr\b/i,
    /\bcbz\b/i
  ].freeze

  EXTENSION_PATTERNS = {
    "m4b" => /\bm4b\b/i,
    "m4a" => /\bm4a\b/i,
    "mp3" => /\bmp3\b/i,
    "epub" => /\bepub\b/i,
    "pdf" => /\bpdf\b/i,
    "mobi" => /\bmobi\b/i,
    "azw3" => /\bazw3\b/i,
    "azw" => /\bazw\b/i,
    "cbz" => /\bcbz\b/i,
    "cbr" => /\bcbr\b/i
  }.freeze

  AUDIOBOOK_SINGLE_FILE_PATTERNS = [
    /\bsingle[\s\-_]?file\b/i,
    /\bone[\s\-_]?file\b/i,
    /\b1[\s\-_]?file\b/i,
    /\bm4b\b/i,
    /\bm4a\b/i
  ].freeze

  AUDIOBOOK_MULTI_FILE_PATTERNS = [
    /\bmulti[\s\-_]?file\b/i,
    /\bchapters?\b/i,
    /\bchaptered\b/i,
    /\bcd\s?\d+\b/i,
    /\bdisc\s?\d+\b/i,
    /\bpart\s?\d+\b/i,
    /\bmp3\b/i
  ].freeze

  BITRATE_PATTERN = /(?<!\d)(\d{2,3})\s?kbps\b/i

  class << self
    # Parse a release title and extract metadata
    # @param title [String] The release title to parse
    # @return [Hash] Parsed metadata including languages, format, etc.
    def parse(title)
      return empty_result if title.blank?

      {
        languages: detect_languages(title),
        is_multi_language: multi_language?(title),
        format: detect_format(title),
        extensions: detect_extensions(title),
        primary_extension: detect_primary_extension(title),
        audio_bitrate_kbps: detect_audio_bitrate(title),
        audiobook_structure: detect_audiobook_structure(title),
        raw_title: title
      }
    end

    # Detect all languages present in a release title
    # @param title [String] The release title
    # @return [Array<String>] Array of detected ISO 639-1 language codes
    def detect_languages(title)
      return [] if title.blank?

      detected = Set.new

      LANGUAGE_PATTERNS.each do |pattern_config|
        pattern = pattern_config[:pattern]
        next unless title.match?(pattern)

        detected.add(pattern_config[:code])
      end

      detected.to_a
    end

    # Check if a release is marked as multi-language
    # @param title [String] The release title
    # @return [Boolean]
    def multi_language?(title)
      return false if title.blank?

      MULTI_LANGUAGE_PATTERNS.any? { |pattern| title.match?(pattern) }
    end

    # Detect the format (audiobook, ebook, or unknown) from the title
    # @param title [String] The release title
    # @return [Symbol, nil] :audiobook, :ebook, or nil if unknown
    def detect_format(title)
      return nil if title.blank?

      return :audiobook if AUDIOBOOK_PATTERNS.any? { |pattern| title.match?(pattern) }
      return :ebook if EBOOK_PATTERNS.any? { |pattern| title.match?(pattern) }

      nil
    end

    def detect_extensions(title)
      return [] if title.blank?

      EXTENSION_PATTERNS.each_with_object([]) do |(extension, pattern), detected|
        detected << extension if title.match?(pattern)
      end
    end

    def detect_primary_extension(title)
      return nil if title.blank?

      EXTENSION_PATTERNS
        .filter_map do |extension, pattern|
          match = title.match(pattern)
          next unless match

          [ extension, match.begin(0) ]
        end
        .min_by(&:last)
        &.first
    end

    def detect_audio_bitrate(title)
      return nil if title.blank?

      match = title.match(BITRATE_PATTERN)
      match && match[1].to_i
    end

    def detect_audiobook_structure(title)
      return nil if title.blank?
      return nil unless detect_format(title) == :audiobook

      return :multi_file if AUDIOBOOK_MULTI_FILE_PATTERNS.any? { |pattern| title.match?(pattern) }
      return :single_file if AUDIOBOOK_SINGLE_FILE_PATTERNS.any? { |pattern| title.match?(pattern) }

      nil
    end

    # Get display info for a language code
    # @param code [String] ISO 639-1 language code
    # @return [Hash, nil] Hash with :name and :flag, or nil if unknown
    def language_info(code)
      LANGUAGES[code]
    end

    # Get all supported language codes
    # @return [Array<String>]
    def supported_language_codes
      LANGUAGES.keys
    end

    # Get languages formatted for select options
    # @return [Array<Array>] Array of [display_name, code] pairs
    def language_options
      LANGUAGES.map { |code, info| [ info[:name], code ] }.sort_by(&:first)
    end

    private

    def empty_result
      {
        languages: [],
        is_multi_language: false,
        format: nil,
        extensions: [],
        primary_extension: nil,
        audio_bitrate_kbps: nil,
        audiobook_structure: nil,
        raw_title: nil
      }
    end
  end
end
