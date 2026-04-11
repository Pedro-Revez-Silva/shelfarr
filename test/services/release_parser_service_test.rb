# frozen_string_literal: true

require "test_helper"

class ReleaseParserServiceTest < ActiveSupport::TestCase
  test "detects English from full word" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.English.Audiobook"), "en"
  end

  test "detects English from ENG code" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.ENG.MP3"), "en"
  end

  test "detects Dutch from full word" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.Dutch.Audiobook"), "nl"
  end

  test "detects Dutch from NL code" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.NL.M4B"), "nl"
  end

  test "detects Dutch from bracketed format" do
    assert_includes ReleaseParserService.detect_languages("Book Title [Dutch] Audiobook"), "nl"
  end

  test "detects German from full word" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.German.Audiobook"), "de"
  end

  test "detects German from DE code" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.DE.MP3"), "de"
  end

  test "detects French from TRUEFRENCH" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.TRUEFRENCH.M4B"), "fr"
  end

  test "detects French from VF" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.VF.Audiobook"), "fr"
  end

  test "detects Spanish from espanol" do
    assert_includes ReleaseParserService.detect_languages("Libro.Titulo.Español.MP3"), "es"
  end

  test "detects Brazilian Portuguese from Dublado" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.Dublado.M4B"), "pt-BR"
  end

  test "detects multiple languages" do
    languages = ReleaseParserService.detect_languages("Book.Title.English.German.Audiobook")
    assert_includes languages, "en"
    assert_includes languages, "de"
  end

  test "returns empty array for no language detected" do
    assert_empty ReleaseParserService.detect_languages("Book.Title.Audiobook.M4B")
  end

  test "returns empty array for blank input" do
    assert_empty ReleaseParserService.detect_languages("")
    assert_empty ReleaseParserService.detect_languages(nil)
  end

  test "multi_language detects MULTI tag" do
    assert ReleaseParserService.multi_language?("Book.Title.MULTI.Audiobook")
  end

  test "multi_language detects Dual tag" do
    assert ReleaseParserService.multi_language?("Book.Title.Dual.Audio.M4B")
  end

  test "multi_language returns false when no multi tag" do
    refute ReleaseParserService.multi_language?("Book.Title.English.Audiobook")
  end

  test "detect_format identifies audiobook from M4B" do
    assert_equal :audiobook, ReleaseParserService.detect_format("Book.Title.M4B")
  end

  test "detect_format identifies audiobook from Audiobook word" do
    assert_equal :audiobook, ReleaseParserService.detect_format("Book Title Audiobook MP3")
  end

  test "detect_format identifies audiobook from Unabridged" do
    assert_equal :audiobook, ReleaseParserService.detect_format("Book Title Unabridged")
  end

  test "detect_format identifies ebook from EPUB" do
    assert_equal :ebook, ReleaseParserService.detect_format("Book.Title.EPUB")
  end

  test "detect_format identifies ebook from MOBI" do
    assert_equal :ebook, ReleaseParserService.detect_format("Book.Title.MOBI")
  end

  test "detect_format returns nil for unknown format" do
    assert_nil ReleaseParserService.detect_format("Book.Title")
  end

  test "parse returns complete result hash" do
    result = ReleaseParserService.parse("Book.Title.Dutch.Audiobook.M4B")

    assert_includes result[:languages], "nl"
    assert_equal :audiobook, result[:format]
    assert_equal [ "m4b" ], result[:extensions]
    assert_equal "m4b", result[:primary_extension]
    assert_equal :single_file, result[:audiobook_structure]
    refute result[:is_multi_language]
    assert_equal "Book.Title.Dutch.Audiobook.M4B", result[:raw_title]
  end

  test "parse returns empty result for blank input" do
    result = ReleaseParserService.parse("")

    assert_empty result[:languages]
    assert_nil result[:format]
    assert_empty result[:extensions]
    assert_nil result[:primary_extension]
    assert_nil result[:audio_bitrate_kbps]
    assert_nil result[:audiobook_structure]
    refute result[:is_multi_language]
    assert_nil result[:raw_title]
  end

  test "detect_extensions returns all supported extensions found" do
    assert_equal [ "epub", "pdf" ], ReleaseParserService.detect_extensions("Book Title EPUB PDF")
  end

  test "detect_primary_extension returns first extension in title order" do
    assert_equal "pdf", ReleaseParserService.detect_primary_extension("Book Title PDF EPUB")
  end

  test "detect_audio_bitrate extracts kbps values" do
    assert_equal 192, ReleaseParserService.detect_audio_bitrate("Book Title Audiobook 192kbps M4B")
  end

  test "detect_audiobook_structure identifies multi file releases" do
    assert_equal :multi_file, ReleaseParserService.detect_audiobook_structure("Book Title Audiobook MP3 Chapters")
  end

  test "language_info returns correct data for known language" do
    info = ReleaseParserService.language_info("en")

    assert_equal "English", info[:name]
    assert_equal "GB", info[:flag]
  end

  test "language_info returns nil for unknown language" do
    assert_nil ReleaseParserService.language_info("xx")
  end

  test "supported_language_codes returns all language codes" do
    codes = ReleaseParserService.supported_language_codes

    assert_includes codes, "en"
    assert_includes codes, "nl"
    assert_includes codes, "de"
    assert_includes codes, "fr"
    assert codes.length >= 20
  end

  test "language_options returns sorted name/code pairs" do
    options = ReleaseParserService.language_options

    assert options.first.is_a?(Array)
    assert_equal 2, options.first.length

    names = options.map(&:first)
    assert_equal names, names.sort
  end

  test "does not falsely detect DE in WEB-DL" do
    languages = ReleaseParserService.detect_languages("Book.Title.WEB-DL.English")

    refute_includes languages, "de"
    assert_includes languages, "en"
  end

  test "detects flemish as Dutch" do
    assert_includes ReleaseParserService.detect_languages("Book.Title.Flemish.Audiobook"), "nl"
  end
end
