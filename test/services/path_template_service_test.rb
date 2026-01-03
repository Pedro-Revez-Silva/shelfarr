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
end
