# frozen_string_literal: true

module WebPreview
  class RequestOptions
    NOTE_LIMIT = 1_000
    BOTH = "both"
    Choice = Data.define(:book_types, :language, :notes)

    def initialize(content_kind: ContentKinds::BOOK)
      @content_kind = content_kind
    end

    def representation
      {
        formats: formats.sort,
        default_format: SettingsService.get(:default_request_format),
        default_language: default_language,
        languages: languages.map { |code, name| { code: code, name: name } },
        note_limit: NOTE_LIMIT
      }
    end

    def choice(params)
      book_types = requested_book_types(params.fetch(:book_type, "ebook"))
      language = requested_language(params[:language])
      notes = requested_notes(params[:notes])
      return if [ book_types, language, notes ].include?(:invalid)

      Choice.new(book_types: book_types, language: language, notes: notes)
    end

    private

    def formats
      RequestOptionPolicy.book_types_for(@content_kind) & BookPage::FORMATS
    end

    def requested_book_types(value)
      return formats.sort if value == BOTH && formats.size > 1
      return [ value ] if value.is_a?(String) && formats.include?(value)

      :invalid
    end

    def requested_language(value)
      return nil if value.nil?
      return :invalid unless value.is_a?(String) && languages.key?(value)

      value
    end

    def requested_notes(value)
      return nil if value.nil?
      return :invalid unless value.is_a?(String) && value.length <= NOTE_LIMIT

      value.strip.presence
    end

    def default_language
      SettingsService.get(:default_language).to_s
    end

    def languages
      @languages ||= begin
        enabled = Array(SettingsService.get(:enabled_languages)).map(&:to_s)
        named = [ default_language, *enabled ].uniq.filter_map do |code|
          info = ReleaseParserService.language_info(code)
          [ code, info[:name] ] if info
        end
        named.sort_by(&:last).to_h
      end
    end
  end
end
