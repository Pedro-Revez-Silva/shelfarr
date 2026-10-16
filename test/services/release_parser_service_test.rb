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

  test "all-caps French titles detect only French as the primary language" do
    {
      "Random.Book.Name.2026.FRENCH.ePUB." => "fr",
      "Title.2024.TRUEFRENCH.EPUB" => "fr"
    }.each do |title, code|
      languages = ReleaseParserService.detect_languages(title)

      assert_equal [ code ], languages, title
      assert_equal code, languages.first, title
    end
  end

  test "does not detect two-letter codes inside longer all-caps words" do
    {
      "Release.DOWNLOAD.EPUB" => "nl",
      "Release.ONLY.EPUB" => "nl",
      "Release.DECODED.EPUB" => "de",
      "Release.DELUXE.EPUB" => "de",
      "Release.FREE.EPUB" => "fr",
      "Release.SERIES.EPUB" => "es",
      "Release.PORTUGUESE.EPUB" => "es",
      "Release.EDITION.EPUB" => "it",
      "Release.DIGITAL.EPUB" => "it",
      "Release.SCRIPT.EPUB" => "pt",
      "Release.TRUE.EPUB" => "ru",
      "Release.COMPLETE.EPUB" => "pl",
      "Release.SAMPLE.EPUB" => "pl",
      "Release.XXCZXX.EPUB" => "cs",
      "Release.XXBGXX.EPUB" => "bg"
    }.each do |title, unexpected|
      refute_includes ReleaseParserService.detect_languages(title), unexpected, title
    end
  end

  test "detects short delimited two-letter language codes" do
    {
      "Book.Title.FR.M4B" => "fr",
      "Book.Title.EN.M4B" => "en",
      "Book Title [EN] M4B" => "en",
      "Book.Title.RU.M4B" => "ru",
      "Book.Title.DE.MP3" => "de",
      "Book.Title.NL.M4B" => "nl",
      "Book.Title.ES.MP3" => "es",
      "Book.Title.IT.MP3" => "it",
      "Book.Title.PT.EPUB" => "pt",
      "Book.Title.PL.EPUB" => "pl",
      "Book.Title.CZ.EPUB" => "cs",
      "Book.Title.BG.EPUB" => "bg"
    }.each do |title, code|
      languages = ReleaseParserService.detect_languages(title)

      assert_equal [ code ], languages, title
      assert_equal code, languages.first, title
    end
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

  test "detects video releases from resolution markers" do
    assert ReleaseParserService.video_release?("The Matrix 1999 1080p BluRay x264-GROUP")
    assert ReleaseParserService.video_release?("Some.Documentary.2023.2160p.REMUX")
  end

  test "detects video releases from episode markers" do
    assert ReleaseParserService.video_release?("Great Show S02E05 720p WEB-DL")
  end

  test "detects video releases from codec and source markers" do
    assert ReleaseParserService.video_release?("Old Film DVDRip XviD")
    assert ReleaseParserService.video_release?("Feature.HEVC.WEBRip")
  end

  test "does not flag plain book releases as video" do
    assert_not ReleaseParserService.video_release?("The Name of the Wind - Patrick Rothfuss")
    assert_not ReleaseParserService.video_release?("The Perfect Run 3 Maxime Durand")
  end

  test "book format markers veto video markers" do
    assert_not ReleaseParserService.video_release?("Filmmaking Basics 1080p Explained EPUB")
    assert_not ReleaseParserService.video_release?("History of Television HDTV Era Audiobook MP3")
  end

  test "video_release? is false for blank titles" do
    assert_not ReleaseParserService.video_release?(nil)
    assert_not ReleaseParserService.video_release?("")
  end
end
