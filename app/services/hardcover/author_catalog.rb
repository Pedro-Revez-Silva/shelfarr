# frozen_string_literal: true

module Hardcover
  # Turns an author's raw Hardcover contributions into the books they wrote.
  #
  # Hardcover credits editors, translators, narrators, illustrators, and
  # foreword writers on the same contributions table as authors, and its
  # community catalog can hold duplicate or translated records of one work.
  # Requesting those would download the wrong books, so they are filtered
  # here and the reasons are reported to the user instead of hidden.
  module AuthorCatalog
    EDITION_MARKERS = /\((?:[^)]*\b(?:edition|unabridged|abridged|illustrated|translation|translated|deluxe|anniversary|reprint|paperback|hardcover|kindle|audiobook|ebook|large print)\b[^)]*)\)/i
    REASONS = {
      role: "credited only as editor, translator, narrator, or another non-author role",
      duplicate: "duplicate records of a book already listed",
      compilation: "box sets and compilations",
      language: "records only available in languages this Shelfarr does not request"
    }.freeze

    Result = Data.define(:entries, :excluded) do
      def excluded_total
        excluded.values.sum
      end
    end

    module_function

    def filter(raw_entries, languages: enabled_languages)
      excluded = Hash.new(0)
      seen_ids = Set.new
      candidates = []

      raw_entries.each do |entry|
        next if seen_ids.include?(entry.id)

        reason = exclusion_reason(entry, languages)
        if reason
          excluded[reason] += 1 unless reason == :role && primary_elsewhere?(raw_entries, entry)
          next
        end

        seen_ids << entry.id
        candidates << entry
      end

      kept = candidates.group_by { |entry| duplicate_key(entry) }.map do |_key, group|
        excluded[:duplicate] += group.size - 1
        group.max_by { |entry| [ entry.users_count.to_i, -entry.id ] }
      end

      Result.new(
        entries: kept.sort_by { |entry| [ entry.release_date || Date.new(9999), entry.title.downcase ] },
        excluded: excluded.reject { |_reason, count| count.zero? }.to_a.to_h
      )
    end

    def exclusion_reason(entry, languages)
      return :role unless Hardcover::API.primary_role?(entry.role)
      return :duplicate if entry.canonical_id.present?
      return :compilation if entry.compilation
      return :language if languages.any? && entry.languages.any? && (entry.languages & languages).empty?

      nil
    end

    # An author can be credited on one book both as author and as, say,
    # illustrator. Only count the role exclusion when no primary credit exists.
    def primary_elsewhere?(raw_entries, entry)
      raw_entries.any? { |other| other.id == entry.id && Hardcover::API.primary_role?(other.role) }
    end

    def duplicate_key(entry)
      title = entry.title.to_s.gsub(EDITION_MARKERS, " ")
      # Fold accents but keep every script's letters so non-Latin titles do
      # not collapse into the same key.
      title = title.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^\p{L}\p{N}]+/, " ").squish
      return [ "id:#{entry.id}" ] if title.blank?

      [ title, entry.series_position.to_s ]
    end

    # The setting's default is stored as a JSON string, so parse it the same
    # way a saved value would be before reading language codes.
    def enabled_languages
      value = SettingsService.get(:enabled_languages)
      if value.is_a?(String)
        value = begin
          JSON.parse(value)
        rescue JSON::ParserError
          value.split(",")
        end
      end
      Array(value).filter_map { |code| code.to_s.strip.downcase[/\A[a-z]{2}/] }.uniq
    end
  end
end
