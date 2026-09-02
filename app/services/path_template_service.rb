# frozen_string_literal: true

# Builds file paths and filenames from templates with variable substitution
# Example path template: "{author}/{title}" -> "Stephen King/The Shining"
# Example filename template: "{author} - {title}" -> "Stephen King - The Shining"
class PathTemplateService
  VARIABLES = %w[
    author title year publisher language series narrator
    authorSort titleSort seriesSort seriesNum
  ].freeze
  FORMATTABLE_VARIABLES = %w[seriesNum].freeze
  DEFAULT_FILENAME_TEMPLATE = "{author} - {title}".freeze
  TOKEN_PATTERN = /\{([^{}]+)\}/

  class UnsafePathError < StandardError; end

  class << self
    # Build a relative path from a template and book metadata
    def build_path(book, template, language: nil, request: nil, search_result: nil)
      render_path_template(
        book,
        template,
        language: language_code_for(book, language: language, request: request, search_result: search_result)
      )
    end

    # ISO language code for {language}: request or download when available,
    # then the book column, then the configured default.
    def language_code_for(book, language: nil, request: nil, search_result: nil)
      normalize_language_code(language).presence ||
        request_language_code(request) ||
        search_result_language_code(search_result) ||
        associated_request_language_code(book) ||
        book_language_code(book) ||
        normalize_language_code(SettingsService.get(:default_language)) ||
        "en"
    end

    # True when the book's path template is blank, meaning files are written
    # directly into the output root rather than a per-book folder
    def flat_output?(book)
      template_for(book).blank?
    end

    # Validate a template string, returns [valid, error_message]
    def validate_template(template, mode: :path)
      return [ true, nil ] if mode == :path && template.blank?
      return [ false, "Template cannot be empty" ] if template.blank?

      parsed_expressions = extract_template_expressions(template)
      parsed_tokens = parsed_expressions.map { |expr| parse_expression(expr) }
      invalid_expressions = parsed_expressions.zip(parsed_tokens).filter_map do |expr, token|
        expr if token.nil?
      end

      if invalid_expressions.any?
        return [ false, "Invalid template expressions: #{invalid_expressions.map { |expr| "{#{expr}}" }.join(', ')}" ]
      end

      variable_names = parsed_tokens.filter_map { |token| token[:name] }
      if mode == :path && !variable_names.intersect?(%w[title titleSort])
        return [ false, "Template must include {title}" ]
      end

      # Check for path traversal attempts
      if mode == :path && (template.include?("..") || template.start_with?("/"))
        return [ false, "Template cannot contain '..' or start with '/'" ]
      end

      if mode == :path && LibraryPathSafety.template_targets_internal_directory?(template)
        return [ false, "Template cannot use a Shelfarr internal staging directory" ]
      end

      # Check for unknown variables
      unknown = variable_names - VARIABLES
      if unknown.any?
        return [ false, "Unknown variables: #{unknown.map { |v| "{#{v}}" }.join(', ')}" ]
      end

      invalid_formats = parsed_tokens.filter_map do |token|
        next unless token[:format].present?
        next if FORMATTABLE_VARIABLES.include?(token[:name])

        "{#{token[:raw]}}"
      end

      if invalid_formats.any?
        return [ false, "Formatting is only supported for: #{FORMATTABLE_VARIABLES.map { |v| "{#{v}:00}" }.join(', ')}" ]
      end

      [ true, nil ]
    end

    # Get the appropriate template for a book type
    def template_for(book)
      if book.audiobook?
        SettingsService.get(:audiobook_path_template, default: "{author}/{title}")
      elsif book.comicbook?
        SettingsService.get(:comicbook_path_template, default: "{series/}{title}")
      else
        SettingsService.get(:ebook_path_template, default: "{author}/{title}")
      end
    end

    # Build the full destination path for a book
    def build_destination(book, base_path: nil, language: nil, request: nil, search_result: nil)
      base = base_path || default_base_path(book)
      template = template_for(book)
      relative_path = build_path(
        book,
        template,
        language: language,
        request: request,
        search_result: search_result
      )

      relative_path.present? ? File.join(base, relative_path) : base
    end

    # Build a filename from a template and book metadata
    # @param book [Book] the book to build filename for
    # @param extension [String] the file extension (e.g., ".epub", ".m4b")
    # @param template [String, nil] optional template override
    # @return [String] the sanitized filename with extension
    def build_filename(book, extension, template: nil, language: nil, request: nil, search_result: nil)
      template ||= filename_template_for(book)
      result = render_filename_template(
        book,
        sanitize_filename_template(template),
        language: language_code_for(book, language: language, request: request, search_result: search_result)
      )
      result = "Unknown" if result.blank?

      # Ensure extension starts with a dot
      ext = extension.to_s
      ext = ".#{ext}" unless ext.start_with?(".")

      "#{result}#{ext}"
    end

    # Get the appropriate filename template for a book type
    def filename_template_for(book)
      if book.audiobook?
        SettingsService.get(:audiobook_filename_template, default: "{author} - {title}")
      elsif book.comicbook?
        SettingsService.get(:comicbook_filename_template, default: "{series - }{seriesNum:00 - }{title}")
      else
        SettingsService.get(:ebook_filename_template, default: "{author} - {title}")
      end
    end

    private

    def default_base_path(book)
      if book.audiobook?
        SettingsService.get(:audiobook_output_path, default: "/audiobooks")
      elsif book.comicbook?
        SettingsService.get(:comicbook_output_path, default: "/comics")
      else
        SettingsService.get(:ebook_output_path, default: "/ebooks")
      end
    end

    def sanitize_filename(name)
      name
        .to_s
        .gsub(/[<>:"\/\\|?*]/, "")  # Remove invalid filename chars
        .gsub(/[\x00-\x1f]/, "")    # Remove control characters
        .strip
        .gsub(/\s+/, " ")           # Collapse whitespace
        .truncate(100, omission: "") # Limit length
    end

    # Sanitize filename template (no path segments allowed)
    def sanitize_filename_template(template)
      return DEFAULT_FILENAME_TEMPLATE if template.blank?

      template.to_s
    end

    # Final path sanitization after variable substitution
    def sanitize_path(path)
      sanitize_path_segments(path).presence || "Unknown"
    end

    # Remove path traversal segments (..) while preserving dots in filenames
    # "../../foo/bar" -> "foo/bar"
    # "J.R.R. Tolkien/The Hobbit" -> "J.R.R. Tolkien/The Hobbit" (unchanged)
    def sanitize_path_segments(path)
      path
        .to_s
        .split("/")
        .reject { |segment| segment == ".." || segment == "." || segment.empty? }
        .join("/")
    end

    def render_path_template(book, template, language:)
      return "" if template.blank?

      result = render_template(book, template, variant: :path, language: language)
      sanitized = sanitize_path(cleanup_path_result(result))
      if LibraryPathSafety.internal_relative_path?(sanitized)
        raise UnsafePathError, "Rendered library path uses a Shelfarr internal staging directory"
      end

      sanitized
    end

    def render_filename_template(book, template, language:)
      result = render_template(book, template, variant: :filename, language: language)
      cleanup_filename_result(sanitize_filename(result))
    end

    def render_template(book, template, variant:, language:)
      values = template_values(book, language: language)
      template.to_s.gsub(TOKEN_PATTERN) do
        expression = Regexp.last_match(1)
        render_expression(expression, values, variant: variant)
      end
    end

    def render_expression(expression, values, variant:)
      token = parse_expression(expression)
      return "{#{expression}}" if token.nil?

      value_definition = values[token[:name]]
      return "{#{expression}}" if value_definition.nil?

      rendered_value = formatted_value(
        value_definition[:value],
        format: token[:format]
      )

      suffix = token[:suffix].to_s

      unless suffix.empty?
        return "" if rendered_value.blank?

        return "#{sanitize_filename(rendered_value)}#{suffix}"
      end

      rendered_value = fallback_value(value_definition, variant) if rendered_value.blank?
      sanitize_filename(rendered_value)
    end

    def formatted_value(value, format:)
      return nil if value.blank?

      if format.present?
        return value.to_i.to_s.rjust(format.length, "0") if integer_like?(value)

        return value.to_s
      end

      value.to_s
    end

    def template_values(book, language:)
      {
        "author" => {
          value: book.author,
          path: "Unknown Author",
          filename: "Unknown Author"
        },
        "title" => {
          value: book.title,
          path: nil,
          filename: nil
        },
        "year" => {
          value: book.year,
          path: "Unknown Year",
          filename: ""
        },
        "publisher" => {
          value: book.publisher,
          path: "Unknown Publisher",
          filename: ""
        },
        "language" => {
          value: language,
          path: "en",
          filename: "en"
        },
        "series" => {
          value: book.series,
          # Empty path fallback: omit the series segment entirely when a book
          # has no series (no "Unknown Series" folder). Empty path segments are
          # collapsed by sanitize_path_segments.
          path: "",
          filename: ""
        },
        "narrator" => {
          value: book.narrator,
          path: "Unknown Narrator",
          filename: ""
        },
        "authorSort" => {
          value: sort_author_name(book.author),
          path: "Unknown Author",
          filename: "Unknown Author"
        },
        "titleSort" => {
          value: sort_title(book.title),
          path: nil,
          filename: nil
        },
        "seriesSort" => {
          value: sort_title(book.series),
          path: "",
          filename: ""
        },
        "seriesNum" => {
          value: book.respond_to?(:series_position) ? book.series_position : nil,
          path: "",
          filename: ""
        }
      }
    end

    def fallback_value(value_definition, variant)
      value_definition.fetch(variant)
    end

    def search_result_language_code(search_result)
      return unless search_result

      if search_result.respond_to?(:detected_language)
        normalize_language_code(search_result.detected_language)
      elsif search_result.respond_to?(:language)
        normalize_language_code(search_result.language)
      end
    end

    def request_language_code(request)
      return unless request

      if request.respond_to?(:effective_language)
        normalize_language_code(request.effective_language)
      elsif request.respond_to?(:language)
        normalize_language_code(request.language)
      end
    end

    def associated_request_language_code(book)
      request_language_code(associated_request(book))
    end

    def associated_request(book)
      return unless book.respond_to?(:persisted?) && book.persisted?
      return unless book.respond_to?(:requests)

      if book.respond_to?(:association) && book.association(:requests).loaded?
        return prefer_request(book.requests.to_a)
      end

      book.requests.open.order(updated_at: :desc, id: :desc).first ||
        book.requests.order(updated_at: :desc, id: :desc).first
    end

    def prefer_request(requests)
      return if requests.blank?

      requests.min_by do |request|
        [
          open_request?(request) ? 0 : 1,
          -request.updated_at.to_f,
          -request.id.to_i
        ]
      end
    end

    def open_request?(request)
      Request::OPEN_STATUSES.include?(request.status.to_s)
    end

    def book_language_code(book)
      return unless book.respond_to?(:language)

      normalize_language_code(book.language)
    end

    def normalize_language_code(value)
      value.to_s.strip.downcase.presence
    end

    def parse_expression(expression)
      expression = expression.to_s
      return nil if expression.empty?

      name_length = 0
      expression.each_byte do |byte|
        if byte == 95 || (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
          name_length += 1
          next
        end
        break
      end

      return nil if name_length == 0

      name = expression[0...name_length]
      rest = expression[name_length..].to_s
      format = nil
      suffix = rest

      if rest.start_with?(":")
        format_and_suffix = rest.delete_prefix(":")
        return nil if format_and_suffix.empty?
        return nil unless format_and_suffix.getbyte(0) == 48

        format_length = 0
        format_and_suffix.each_byte do |byte|
          break if byte != 48
          format_length += 1
        end

        return nil if format_length == 0

        format = format_and_suffix[0...format_length]
        suffix = format_and_suffix[format_length..].to_s
      end

      {
        raw: expression,
        name: name,
        format: format,
        suffix: suffix
      }
    end

    def extract_template_expressions(template)
      template.to_s.scan(TOKEN_PATTERN).flatten
    end

    def cleanup_filename_result(result)
      result
        .gsub(/\s*\(\s*\)\s*/, " ")     # Remove empty parentheses
        .gsub(/\s*\[\s*\]\s*/, " ")     # Remove empty brackets
        .gsub(/\s*-\s*-\s*/, " - ")     # Collapse double dashes
        .gsub(/\s*-\s*$/, "")           # Remove trailing dashes
        .gsub(/^\s*-\s*/, "")           # Remove leading dashes
        .gsub(/\s+/, " ")               # Collapse whitespace
        .strip
    end

    def cleanup_path_result(result)
      result
        .gsub(%r{/\s*-\s*}, "/")        # Drop stray " - " after an empty segment
        .gsub(/\s*-\s*\/+/, "/")        # Drop stray " - " before a path separator
        .gsub(%r{/+}, "/")              # Collapse repeated separators before final sanitization
        .gsub(%r{(^|/)\s*-\s*($|/)}, "\\1\\2")
        .gsub(/\s+/, " ")
        .strip
    end

    def integer_like?(value)
      value.to_s.match?(/\A\d+\z/)
    end

    def sort_author_name(author)
      return nil if author.blank?
      return author if author.include?(",") || author.match?(/\s(?:and|&)\s/)

      parts = author.split
      return author if parts.length < 2

      "#{parts.last}, #{parts[0...-1].join(' ')}"
    end

    def sort_title(title)
      return nil if title.blank?

      if (match = title.match(/\A(The|An|A)\s+(.+)\z/i))
        "#{match[2]}, #{match[1]}"
      else
        title
      end
    end
  end
end
