# frozen_string_literal: true

# Builds file paths from templates with variable substitution
# Example template: "{author}/{title}" -> "Stephen King/The Shining"
class PathTemplateService
  VARIABLES = %w[author title year publisher language].freeze

  class << self
    # Build a relative path from a template and book metadata
    def build_path(book, template)
      result = template.dup

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

      result
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
  end
end
