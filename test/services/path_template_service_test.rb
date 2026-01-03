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
    assert_not_includes result, ".."
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
end
