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
  DEFAULT_TEMPLATE = "{author}/{title}".freeze
  DEFAULT_FILENAME_TEMPLATE = "{author} - {title}".freeze
  TOKEN_PATTERN = /\{([^{}]+)\}/

  class << self
    # Build a relative path from a template and book metadata
    def build_path(book, template)
      render_path_template(book, sanitize_template(template))
    end

    # Validate a template string, returns [valid, error_message]
    def validate_template(template, mode: :path)
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
      else
        SettingsService.get(:ebook_path_template, default: "{author}/{title}")
      end
    end

    # Build the full destination path for a book
    def build_destination(book, base_path: nil)
      base = base_path || default_base_path(book)
      template = template_for(book)
      relative_path = build_path(book, template)

      File.join(base, relative_path)
    end

    # Build a filename from a template and book metadata
    # @param book [Book] the book to build filename for
    # @param extension [String] the file extension (e.g., ".epub", ".m4b")
    # @param template [String, nil] optional template override
    # @return [String] the sanitized filename with extension
    def build_filename(book, extension, template: nil)
      template ||= filename_template_for(book)
      result = render_filename_template(book, sanitize_filename_template(template))
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
      else
        SettingsService.get(:ebook_filename_template, default: "{author} - {title}")
      end
    end

    private

    def default_base_path(book)
      if book.audiobook?
        SettingsService.get(:audiobook_output_path, default: "/audiobooks")
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

    # Sanitize template to prevent path traversal
    def sanitize_template(template)
      return DEFAULT_TEMPLATE if template.blank?

      template.to_s
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

    def render_path_template(book, template)
      result = render_template(book, template, variant: :path)
      sanitize_path(cleanup_path_result(result))
    end

    def render_filename_template(book, template)
      result = render_template(book, template, variant: :filename)
      cleanup_filename_result(sanitize_filename(result))
    end

    def render_template(book, template, variant:)
      template.to_s.gsub(TOKEN_PATTERN) do
        expression = Regexp.last_match(1)
        render_expression(book, expression, variant: variant)
      end
    end

    def render_expression(book, expression, variant:)
      token = parse_expression(expression)
      return "{#{expression}}" if token.nil?

      value_definition = template_values(book)[token[:name]]
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

    def template_values(book)
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
          value: book.language.presence || "en",
          path: "en",
          filename: "en"
        },
        "series" => {
          value: book.series,
          path: "Unknown Series",
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

    def parse_expression(expression)
      match = expression.match(/\A(?<name>\w+)(?<rest>.*)\z/)
      return nil unless match

      name = match[:name]
      rest = match[:rest].to_s
      format = nil
      suffix = rest

      if rest.start_with?(":")
        format_and_suffix = rest.delete_prefix(":")
        format_match = format_and_suffix.match(/\A(?<format>0+)(?<suffix>.*)\z/)
        return nil unless format_match

        format = format_match[:format]
        suffix = format_match[:suffix].to_s
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
