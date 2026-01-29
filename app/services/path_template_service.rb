# frozen_string_literal: true

# Builds file paths and filenames from templates with variable substitution
# Example path template: "{author}/{title}" -> "Stephen King/The Shining"
# Example filename template: "{author} - {title}" -> "Stephen King - The Shining"
class PathTemplateService
  VARIABLES = %w[author title year publisher language].freeze
  DEFAULT_TEMPLATE = "{author}/{title}".freeze
  DEFAULT_FILENAME_TEMPLATE = "{author} - {title}".freeze

  class << self
    # Build a relative path from a template and book metadata
    def build_path(book, template)
      safe_template = sanitize_template(template)
      result = safe_template.dup

      substitutions = {
        "{author}" => book.author.presence || "Unknown Author",
        "{title}" => book.title,
        "{year}" => book.year&.to_s.presence || "Unknown Year",
        "{publisher}" => book.publisher.presence || "Unknown Publisher",
        "{language}" => book.language || "en"
      }

      substitutions.each do |variable, value|
        result = result.gsub(variable, sanitize_filename(value))
      end

      # Final safety check - remove any remaining path traversal
      sanitize_path(result)
    end

    # Validate a template string, returns [valid, error_message]
    def validate_template(template)
      return [ false, "Template cannot be empty" ] if template.blank?
      return [ false, "Template must include {title}" ] unless template.include?("{title}")

      # Check for path traversal attempts
      if template.include?("..") || template.start_with?("/")
        return [ false, "Template cannot contain '..' or start with '/'" ]
      end

      # Check for unknown variables
      unknown = template.scan(/\{(\w+)\}/).flatten - VARIABLES
      if unknown.any?
        return [ false, "Unknown variables: #{unknown.map { |v| "{#{v}}" }.join(', ')}" ]
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
      safe_template = sanitize_filename_template(template)
      result = safe_template.dup

      substitutions = {
        "{author}" => book.author.presence || "Unknown Author",
        "{title}" => book.title,
        "{year}" => book.year&.to_s.presence || ""
      }

      substitutions.each do |variable, value|
        result = result.gsub(variable, sanitize_filename(value))
      end

      # Remove empty placeholders and clean up
      result = result
        .gsub(/\s*\(\s*\)\s*/, " ")     # Remove empty parentheses
        .gsub(/\s*\[\s*\]\s*/, " ")     # Remove empty brackets
        .gsub(/\s*-\s*-\s*/, " - ")     # Collapse double dashes
        .gsub(/\s*-\s*$/, "")           # Remove trailing dashes
        .gsub(/^\s*-\s*/, "")           # Remove leading dashes
        .gsub(/\s+/, " ")               # Collapse whitespace
        .strip
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

      sanitize_path_segments(template).presence || DEFAULT_TEMPLATE
    end

    # Sanitize filename template (no path segments allowed)
    def sanitize_filename_template(template)
      return DEFAULT_FILENAME_TEMPLATE if template.blank?

      # Remove any path separators from filename template
      sanitized = template.gsub(/[\/\\]/, "")
      sanitized.presence || DEFAULT_FILENAME_TEMPLATE
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
  end
end
