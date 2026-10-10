# frozen_string_literal: true

require "test_helper"

class Hardcover::AuthorCatalogTest < ActiveSupport::TestCase
  def entry(id, title: "Book #{id}", role: nil, **attrs)
    book = hardcover_book(id: id, title: title, **attrs.slice(:canonical_id, :compilation, :users_count, :release_date, :series, :position))
    Hardcover::API.parse_book(book, role: role, languages: attrs.fetch(:languages, [ "en" ]))
  end

  test "keeps written books and excludes editor, translator, and narrator-only credits" do
    result = Hardcover::AuthorCatalog.filter([
      entry(1, title: "Written Novel"),
      entry(2, title: "Edited Anthology", role: "Editor"),
      entry(3, title: "Translated Work", role: "Translator"),
      entry(4, title: "Narrated Audiobook", role: "Narrator"),
      entry(5, title: "Co-written", role: "Author")
    ], languages: [ "en" ])

    assert_equal [ 1, 5 ], result.entries.map(&:id).sort
    assert_equal 3, result.excluded[:role]
  end

  test "an author credited twice on one book is kept through the primary credit" do
    result = Hardcover::AuthorCatalog.filter([ entry(7, role: "Illustrator"), entry(7, role: nil) ], languages: [ "en" ])

    assert_equal [ 7 ], result.entries.map(&:id)
    assert_nil result.excluded[:role]
  end

  test "collapses duplicate records of one work and keeps the most-read record" do
    result = Hardcover::AuthorCatalog.filter([
      entry(10, title: "The Book", users_count: 5),
      entry(11, title: "The Book (Spanish Edition)", users_count: 900),
      entry(12, title: "The Book: Anniversary", users_count: 1),
      entry(13, title: "Merged Duplicate", canonical_id: 10)
    ], languages: [ "en" ])

    assert_includes result.entries.map(&:id), 11
    assert_not_includes result.entries.map(&:id), 10
    assert_not_includes result.entries.map(&:id), 13
    assert_includes result.entries.map(&:id), 12, "a different subtitle is a different book"
    assert_equal 2, result.excluded[:duplicate]
  end

  test "keeps different books in a series that share a title prefix" do
    result = Hardcover::AuthorCatalog.filter([
      entry(20, title: "Mistborn: The Final Empire", series: "Mistborn", position: 1),
      entry(21, title: "Mistborn: The Well of Ascension", series: "Mistborn", position: 2)
    ], languages: [ "en" ])

    assert_equal [ 20, 21 ], result.entries.map(&:id).sort
  end

  test "does not merge different non-Latin titles" do
    result = Hardcover::AuthorCatalog.filter([ entry(30, title: "ノルウェイの森", languages: [ "ja" ]), entry(31, title: "海辺のカフカ", languages: [ "ja" ]) ], languages: [])

    assert_equal 2, result.entries.size
  end

  test "excludes compilations and records only in languages this instance does not request" do
    result = Hardcover::AuthorCatalog.filter([
      entry(40, title: "Box Set", compilation: true),
      entry(41, title: "Translated Record", languages: [ "de" ]),
      entry(42, title: "Unknown Language", languages: []),
      entry(43, title: "English", languages: [ "en", "de" ])
    ], languages: [ "en" ])

    assert_equal [ 42, 43 ], result.entries.map(&:id).sort
    assert_equal 1, result.excluded[:compilation]
    assert_equal 1, result.excluded[:language]
  end

  test "reads the default and saved language settings" do
    Setting.where(key: "enabled_languages").delete_all
    assert_equal [ "en" ], Hardcover::AuthorCatalog.enabled_languages

    SettingsService.set(:enabled_languages, [ "en", "PT-br", "fr" ])
    assert_equal %w[en pt fr], Hardcover::AuthorCatalog.enabled_languages
  end
end
