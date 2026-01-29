# frozen_string_literal: true

require "test_helper"

class PathTemplateServiceTest < ActiveSupport::TestCase
  setup do
    @book = books(:audiobook_acquired)
    @book.update!(
      author: "Stephen King",
      title: "The Shining",
      year: 1977,
      publisher: "Doubleday",
      language: "en"
    )
  end

  test "builds path with default template" do
    result = PathTemplateService.build_path(@book, "{author}/{title}")
    assert_equal "Stephen King/The Shining", result
  end

  test "builds path with year template" do
    result = PathTemplateService.build_path(@book, "{year}/{author}/{title}")
    assert_equal "1977/Stephen King/The Shining", result
  end

  test "builds flat path template" do
    result = PathTemplateService.build_path(@book, "{author} - {title}")
    assert_equal "Stephen King - The Shining", result
  end

  test "handles missing author" do
    @book.update!(author: nil)
    result = PathTemplateService.build_path(@book, "{author}/{title}")
    assert_equal "Unknown Author/The Shining", result
  end

  test "handles missing year" do
    @book.update!(year: nil)
    result = PathTemplateService.build_path(@book, "{year}/{title}")
    assert_equal "Unknown Year/The Shining", result
  end

  test "handles missing publisher" do
    @book.update!(publisher: nil)
    result = PathTemplateService.build_path(@book, "{publisher}/{title}")
    assert_equal "Unknown Publisher/The Shining", result
  end

  test "sanitizes invalid filename characters" do
    @book.update!(author: "Author: With/Bad\\Chars?")
    result = PathTemplateService.build_path(@book, "{author}/{title}")
    assert_equal "Author WithBadChars/The Shining", result
  end

  test "template_for returns audiobook template for audiobooks" do
    Setting.create!(key: "audiobook_path_template", value: "{year}/{author}", value_type: "string", category: "paths")

    template = PathTemplateService.template_for(@book)
    assert_equal "{year}/{author}", template
  end

  test "template_for returns ebook template for ebooks" do
    ebook = books(:ebook_pending)
    Setting.create!(key: "ebook_path_template", value: "{author}", value_type: "string", category: "paths")

    template = PathTemplateService.template_for(ebook)
    assert_equal "{author}", template
  end

  test "build_destination combines base path and template" do
    result = PathTemplateService.build_destination(@book, base_path: "/audiobooks")
    assert_equal "/audiobooks/Stephen King/The Shining", result
  end

  # Security / Validation tests

  test "removes path traversal from template" do
    result = PathTemplateService.build_path(@book, "../../{author}/{title}")
    assert_equal "Stephen King/The Shining", result
  end

  test "preserves dots in author names" do
    @book.update!(author: "J.R.R. Tolkien", title: "The Hobbit")
    result = PathTemplateService.build_path(@book, "{author}/{title}")
    assert_equal "J.R.R. Tolkien/The Hobbit", result
  end

  test "preserves dots in titles" do
    @book.update!(title: "What If... Marvel")
    result = PathTemplateService.build_path(@book, "{author}/{title}")
    assert_equal "Stephen King/What If... Marvel", result
  end

  test "removes leading slashes from template" do
    result = PathTemplateService.build_path(@book, "/{author}/{title}")
    assert_equal "Stephen King/The Shining", result
  end

  test "handles empty template with default" do
    result = PathTemplateService.build_path(@book, "")
    assert_equal "Stephen King/The Shining", result
  end

  test "handles nil template with default" do
    result = PathTemplateService.build_path(@book, nil)
    assert_equal "Stephen King/The Shining", result
  end

  test "collapses multiple slashes" do
    result = PathTemplateService.build_path(@book, "{author}//{title}")
    assert_equal "Stephen King/The Shining", result
  end

  test "validate_template returns error for empty template" do
    valid, error = PathTemplateService.validate_template("")
    assert_not valid
    assert_equal "Template cannot be empty", error
  end

  test "validate_template returns error for missing title" do
    valid, error = PathTemplateService.validate_template("{author}")
    assert_not valid
    assert_equal "Template must include {title}", error
  end

  test "validate_template returns error for path traversal" do
    valid, error = PathTemplateService.validate_template("../{title}")
    assert_not valid
    assert_includes error, ".."
  end

  test "validate_template returns error for unknown variables" do
    valid, error = PathTemplateService.validate_template("{author}/{title}/{unknown}")
    assert_not valid
    assert_includes error, "{unknown}"
  end

  test "validate_template accepts valid template" do
    valid, error = PathTemplateService.validate_template("{year}/{author}/{title}")
    assert valid
    assert_nil error
  end

  # Filename template tests

  test "build_filename with default template" do
    result = PathTemplateService.build_filename(@book, ".epub")
    assert_equal "Stephen King - The Shining.epub", result
  end

  test "build_filename with custom template" do
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{title} by {author}")
    assert_equal "The Shining by Stephen King.m4b", result
  end

  test "build_filename includes year when in template" do
    result = PathTemplateService.build_filename(@book, ".epub", template: "{author} - {title} ({year})")
    assert_equal "Stephen King - The Shining (1977).epub", result
  end

  test "build_filename handles missing year gracefully" do
    @book.update!(year: nil)
    result = PathTemplateService.build_filename(@book, ".epub", template: "{author} - {title} - {year}")
    # Empty year should be cleaned up, not leave trailing separator
    assert_equal "Stephen King - The Shining.epub", result
  end

  test "build_filename handles missing year in parentheses" do
    @book.update!(year: nil)
    result = PathTemplateService.build_filename(@book, ".epub", template: "{author} - {title} ({year})")
    # Empty parentheses should be removed
    assert_equal "Stephen King - The Shining.epub", result
  end

  test "build_filename handles missing year in middle of template" do
    @book.update!(year: nil)
    result = PathTemplateService.build_filename(@book, ".epub", template: "{author} ({year}) - {title}")
    # Empty parentheses should be removed
    assert_equal "Stephen King - The Shining.epub", result
  end

  test "build_filename handles missing author" do
    @book.update!(author: nil)
    result = PathTemplateService.build_filename(@book, ".epub")
    assert_equal "Unknown Author - The Shining.epub", result
  end

  test "build_filename sanitizes invalid characters" do
    @book.update!(title: "Book: A Story?")
    result = PathTemplateService.build_filename(@book, ".epub")
    assert_equal "Stephen King - Book A Story.epub", result
  end

  test "build_filename strips path separators from template" do
    result = PathTemplateService.build_filename(@book, ".epub", template: "{author}/{title}")
    assert_equal "Stephen KingThe Shining.epub", result
  end

  test "build_filename adds dot to extension if missing" do
    result = PathTemplateService.build_filename(@book, "epub")
    assert_equal "Stephen King - The Shining.epub", result
  end

  test "filename_template_for returns audiobook template for audiobooks" do
    Setting.create!(key: "audiobook_filename_template", value: "{title}", value_type: "string", category: "paths")

    template = PathTemplateService.filename_template_for(@book)
    assert_equal "{title}", template
  end

  test "filename_template_for returns ebook template for ebooks" do
    ebook = books(:ebook_pending)
    Setting.create!(key: "ebook_filename_template", value: "{title} - {author}", value_type: "string", category: "paths")

    template = PathTemplateService.filename_template_for(ebook)
    assert_equal "{title} - {author}", template
  end
end
