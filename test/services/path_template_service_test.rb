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

  test "builds path with language template for non-default language" do
    @book.update!(language: "es")
    result = PathTemplateService.build_path(@book, "{language}/{author}/{title}")
    assert_equal "es/Stephen King/The Shining", result
  end

  test "builds path with language template defaults to en for missing language" do
    @book.update!(language: nil)
    result = PathTemplateService.build_path(@book, "{language}/{author}/{title}")
    assert_equal "en/Stephen King/The Shining", result
  end

  test "uses configured default language when book language is blank" do
    SettingsService.set(:default_language, "de")
    @book.update!(language: nil)

    result = PathTemplateService.build_path(@book, "{language}/{author}/{title}")
    assert_equal "de/Stephen King/The Shining", result
  end

  test "uses a completed request language when no open request exists" do
    @book.update!(language: "en")
    Request.create!(
      book: @book,
      user: users(:one),
      language: "es",
      status: :completed
    )

    result = PathTemplateService.build_path(@book, "{language}/{author}/{title}")
    assert_equal "es/Stephen King/The Shining", result
  end

  test "uses associated request language when book language is the column default" do
    @book.update!(language: "en")
    Request.create!(
      book: @book,
      user: users(:one),
      language: "es",
      status: :downloading
    )

    result = PathTemplateService.build_path(@book, "{language}/{author}/{title}")
    assert_equal "es/Stephen King/The Shining", result
  end

  test "uses passed request language over book language" do
    @book.update!(language: "en")
    request = Request.create!(
      book: @book,
      user: users(:one),
      language: "es",
      status: :downloading
    )

    result = PathTemplateService.build_path(@book, "{language}/{author}/{title}", request: request)
    assert_equal "es/Stephen King/The Shining", result
  end

  test "uses download language when no request language is available" do
    @book.update!(language: "en")
    search_result = Struct.new(:detected_language).new("es")

    result = PathTemplateService.build_path(
      @book,
      "{language}/{author}/{title}",
      search_result: search_result
    )
    assert_equal "es/Stephen King/The Shining", result
  end

  test "prefers request language over download language" do
    @book.update!(language: "en")
    request = Request.create!(
      book: @book,
      user: users(:one),
      language: "es",
      status: :downloading
    )
    search_result = Struct.new(:detected_language).new("en")

    result = PathTemplateService.build_path(
      @book,
      "{language}/{author}/{title}",
      request: request,
      search_result: search_result
    )
    assert_equal "es/Stephen King/The Shining", result
  end

  test "uses explicit language override over request and download language" do
    request = Request.create!(
      book: @book,
      user: users(:one),
      language: "es",
      status: :downloading
    )
    search_result = Struct.new(:detected_language).new("de")

    result = PathTemplateService.build_path(
      @book,
      "{language}/{title}",
      language: "fr",
      request: request,
      search_result: search_result
    )
    assert_equal "fr/The Shining", result
  end

  test "prefers an open request language over a completed request on the same book" do
    @book.update!(language: "en")
    Request.create!(
      book: @book,
      user: users(:one),
      language: "fr",
      status: :completed
    )
    Request.create!(
      book: @book,
      user: users(:one),
      language: "es",
      status: :downloading
    )

    result = PathTemplateService.build_path(@book, "{language}/{title}")
    assert_equal "es/The Shining", result
  end

  test "build_filename uses request language in {language}" do
    Request.create!(
      book: @book,
      user: users(:one),
      language: "es",
      status: :downloading
    )

    result = PathTemplateService.build_filename(@book, ".m4b", template: "{language} - {title}")
    assert_equal "es - The Shining.m4b", result
  end

  test "explicit request language is consistent across path and filename with a newer competing request" do
    request = Request.create!(
      book: @book,
      user: users(:one),
      language: "es",
      status: :downloading
    )
    Request.create!(
      book: @book,
      user: users(:two),
      language: "fr",
      status: :downloading
    )

    path = PathTemplateService.build_path(@book, "{language}/{title}", request: request)
    filename = PathTemplateService.build_filename(
      @book,
      ".m4b",
      template: "{language}-{title}",
      request: request
    )

    assert_equal "es/The Shining", path
    assert_equal "es-The Shining.m4b", filename
  end

  test "templates without language do not query associated requests" do
    request_queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      request_queries << payload[:sql] if payload[:sql].match?(/FROM \"requests\"/i)
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      PathTemplateService.build_path(@book, "{author}/{title}")
      PathTemplateService.build_filename(@book, ".m4b", template: "{author}-{title}")
    end

    assert_empty request_queries
  end

  test "builds path with series variable" do
    @book.update!(series: "The Dark Tower")
    result = PathTemplateService.build_path(@book, "{author}/{series}/{title}")
    assert_equal "Stephen King/The Dark Tower/The Shining", result
  end

  test "handles missing series" do
    @book.update!(series: nil)
    result = PathTemplateService.build_path(@book, "{author}/{series}/{title}")
    assert_equal "Stephen King/The Shining", result
  end

  test "supports optional suffixes for missing path variables" do
    @book.update!(series: nil)
    result = PathTemplateService.build_path(@book, "{author}/{series/}{title}")
    assert_equal "Stephen King/The Shining", result
  end

  test "supports optional suffixes for present path variables" do
    @book.update!(series: "The Dark Tower")
    result = PathTemplateService.build_path(@book, "{author}/{series/}{title}")
    assert_equal "Stephen King/The Dark Tower/The Shining", result
  end

  test "builds path with author sort variable" do
    result = PathTemplateService.build_path(@book, "{authorSort}/{title}")
    assert_equal "King, Stephen/The Shining", result
  end

  test "builds path with title sort variable" do
    @book.update!(title: "The Shining")
    result = PathTemplateService.build_path(@book, "{author}/{titleSort}")
    assert_equal "Stephen King/Shining, The", result
  end

  test "builds path with series sort variable" do
    @book.update!(series: "The Dark Tower")
    result = PathTemplateService.build_path(@book, "{author}/{seriesSort}/{title}")
    assert_equal "Stephen King/Dark Tower, The/The Shining", result
  end

  test "builds path with series number padding" do
    @book.update!(series_position: "3")
    result = PathTemplateService.build_path(@book, "{author}/{seriesNum:00} - {title}")
    assert_equal "Stephen King/03 - The Shining", result
  end

  test "build_path removes separator when series number is missing" do
    @book.update!(series_position: nil)
    result = PathTemplateService.build_path(@book, "{author}/{seriesNum:00} - {title}")
    assert_equal "Stephen King/The Shining", result
  end

  test "builds path with narrator variable" do
    @book.update!(narrator: "Frank Muller")
    result = PathTemplateService.build_path(@book, "{author}/{narrator}/{title}")
    assert_equal "Stephen King/Frank Muller/The Shining", result
  end

  test "handles missing narrator" do
    @book.update!(narrator: nil)
    result = PathTemplateService.build_path(@book, "{narrator}/{title}")
    assert_equal "Unknown Narrator/The Shining", result
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

  test "build_destination uses base path when audiobook path template is blank" do
    SettingsService.set(:audiobook_path_template, "")

    result = PathTemplateService.build_destination(@book, base_path: "/audiobooks")
    assert_equal "/audiobooks", result
  end

  test "build_destination uses base path when ebook path template is blank" do
    ebook = books(:ebook_pending)
    ebook.update!(author: "Frank Herbert", title: "Dune")
    SettingsService.set(:ebook_path_template, "")

    result = PathTemplateService.build_destination(ebook, base_path: "/ebooks")
    assert_equal "/ebooks", result
  end

  test "flat_output? reflects whether the book's path template is blank" do
    SettingsService.set(:audiobook_path_template, "")
    assert PathTemplateService.flat_output?(@book)

    SettingsService.set(:audiobook_path_template, "{author}/{title}")
    assert_not PathTemplateService.flat_output?(@book)
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

  test "handles empty path template as flat output" do
    result = PathTemplateService.build_path(@book, "")
    assert_equal "", result
  end

  test "handles nil path template as flat output" do
    result = PathTemplateService.build_path(@book, nil)
    assert_equal "", result
  end

  test "collapses multiple slashes" do
    result = PathTemplateService.build_path(@book, "{author}//{title}")
    assert_equal "Stephen King/The Shining", result
  end

  test "validate_template accepts empty path template" do
    valid, error = PathTemplateService.validate_template("")
    assert valid
    assert_nil error
  end

  test "validate_template returns error for empty filename template" do
    valid, error = PathTemplateService.validate_template("", mode: :filename)
    assert_not valid
    assert_equal "Template cannot be empty", error
  end

  test "validate_template returns error for missing title" do
    valid, error = PathTemplateService.validate_template("{author}")
    assert_not valid
    assert_equal "Template must include {title}", error
  end

  test "validate_template allows filename templates without title for backward compatibility" do
    valid, error = PathTemplateService.validate_template("{author}", mode: :filename)
    assert valid
    assert_nil error
  end

  test "validate_template returns error for path traversal" do
    valid, error = PathTemplateService.validate_template("../{title}")
    assert_not valid
    assert_includes error, ".."
  end

  test "rejects direct-download staging in configured and rendered paths" do
    valid, error = PathTemplateService.validate_template(".shelfarr-staging-v2/{title}")

    assert_not valid
    assert_match(/internal staging/i, error)

    @book.update!(author: DirectDownloadFileService::STAGING_DIRECTORY)
    assert_raises(PathTemplateService::UnsafePathError) do
      PathTemplateService.build_path(@book, "{author}/{title}")
    end

    @book.update!(author: DirectDownloadFileService::STAGING_DIRECTORY.upcase)
    assert_raises(PathTemplateService::UnsafePathError) do
      PathTemplateService.build_path(@book, "{author}/{title}")
    end
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

  test "validate_template accepts series variable" do
    valid, error = PathTemplateService.validate_template("{author}/{series}/{title}")
    assert valid
    assert_nil error
  end

  test "validate_template accepts narrator variable" do
    valid, error = PathTemplateService.validate_template("{narrator}/{title}")
    assert valid
    assert_nil error
  end

  test "validate_template accepts optional suffix syntax" do
    valid, error = PathTemplateService.validate_template("{author}/{series/}{title}")
    assert valid
    assert_nil error
  end

  test "validate_template accepts sort variables" do
    valid, error = PathTemplateService.validate_template("{authorSort}/{titleSort}")
    assert valid
    assert_nil error
  end

  test "validate_template accepts series number formatting" do
    valid, error = PathTemplateService.validate_template("{seriesNum:00} - {title}", mode: :filename)
    assert valid
    assert_nil error
  end

  test "validate_template rejects invalid series number formatting" do
    valid, error = PathTemplateService.validate_template("{seriesNum:abc} - {title}", mode: :filename)
    assert_not valid
    assert_match(/Invalid template expressions/, error)
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

  test "build_filename includes series when in template" do
    @book.update!(series: "The Dark Tower")
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{series} - {title}")
    assert_equal "The Dark Tower - The Shining.m4b", result
  end

  test "build_filename includes narrator when in template" do
    @book.update!(narrator: "Frank Muller")
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{title} ({narrator})")
    assert_equal "The Shining (Frank Muller).m4b", result
  end

  test "build_filename handles missing series gracefully" do
    @book.update!(series: nil)
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{author} - {title} - {series}")
    assert_equal "Stephen King - The Shining.m4b", result
  end

  test "build_filename handles missing narrator gracefully" do
    @book.update!(narrator: nil)
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{author} - {title} ({narrator})")
    assert_equal "Stephen King - The Shining.m4b", result
  end

  test "build_filename supports optional suffixes for missing variables" do
    @book.update!(series: nil)
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{author} - {series - }{title}")
    assert_equal "Stephen King - The Shining.m4b", result
  end

  test "build_filename supports optional suffixes for present variables" do
    @book.update!(series: "Dark Tower")
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{author} - {series - }{title}")
    assert_equal "Stephen King - Dark Tower - The Shining.m4b", result
  end

  test "build_filename supports author sort variable" do
    result = PathTemplateService.build_filename(@book, ".epub", template: "{authorSort} - {title}")
    assert_equal "King, Stephen - The Shining.epub", result
  end

  test "build_filename supports title sort variable" do
    result = PathTemplateService.build_filename(@book, ".epub", template: "{titleSort}")
    assert_equal "Shining, The.epub", result
  end

  test "build_filename supports series number padding" do
    @book.update!(series_position: "7")
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{seriesNum:000} - {title}")
    assert_equal "007 - The Shining.m4b", result
  end

  test "build_filename omits missing series number" do
    @book.update!(series_position: nil)
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{seriesNum:00} - {title}")
    assert_equal "The Shining.m4b", result
  end

  test "build_filename removes surrounding separator when series number is missing" do
    @book.update!(series_position: nil)
    result = PathTemplateService.build_filename(@book, ".m4b", template: "{author} - {seriesNum:00} - {title}")
    assert_equal "Stephen King - The Shining.m4b", result
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
