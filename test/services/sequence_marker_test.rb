# frozen_string_literal: true

require "test_helper"

class SequenceMarkerTest < ActiveSupport::TestCase
  test "reads canonical Roman numbers above one hundred without treating prose as numbers" do
    { "CI" => "101", "CD" => "400", "D" => "500", "CMXCIX" => "999", "MMMCMXCIX" => "3999" }.each do |roman, number|
      assert_equal [ number ], SequenceMarker.numbers("Series Tome #{roman}")
      assert_equal "Series volume #{number}", SequenceMarker.neutralize("Series Volume #{roman}")
    end
    assert_empty SequenceMarker.numbers("Book mix")
    assert_empty SequenceMarker.numbers("Book did")
    assert SequenceMarker.conflict?("Volume CI", "Tome CII")
  end

  test "keeps Roman-looking prose while accepting explicit numerals" do
    [ "Il Libro di famiglia", "Libro mi vida", "Livre dix histoires", "Book Mix" ].each do |title|
      assert_empty SequenceMarker.numbers(title), title
      assert_equal title, SequenceMarker.neutralize(title)
      assert_equal title, SequenceMarker.strip(title)
    end
    assert_equal [ "101" ], SequenceMarker.numbers("Volume ci")
    assert SequenceMarker.conflict?("Volume ci", "Tome cii")
    assert_equal [ "501" ], SequenceMarker.numbers("Volume DI")
    assert_equal [ "1009" ], SequenceMarker.numbers("Volume MIX")
    assert_equal "Series Volume MIX", SequenceMarker.without_author_credit(
      "Series Volume MIX - Author Name", author: "Author Name", protected_title: "Series Tome 1009"
    ).strip.delete_suffix("-").strip
  end

  test "conflicts when the first volume differs even if only one side has a part" do
    assert SequenceMarker.conflict?(
      "The Stormlight Archive Book 2",
      "The Stormlight Archive Book 3 Part 1"
    )
    assert SequenceMarker.conflict?(
      "The Stormlight Archive Book 3 Part 1",
      "The Stormlight Archive Book 2"
    )
    assert_not SequenceMarker.conflict?(
      "The Stormlight Archive Book 2",
      "The Stormlight Archive Book 2 Part 1"
    )
    assert_not SequenceMarker.conflict?("Tome 3", "Tome 3 Partie 1")
    assert SequenceMarker.conflict?("Tome 3 Partie 1", "Tome 3 Partie 2")
    assert_not SequenceMarker.conflict?("Part 2", "Tome 2")
  end

  test "does not read the t in a contraction as a volume marker" do
    [ "Don't I Know You?", "Don’t I Know You?" ].each do |title|
      assert_empty SequenceMarker.numbers(title), title
      assert_not_includes SequenceMarker.neutralize(title), "volume"
      assert_not_includes SequenceMarker.strip(title), "1"
    end
  end

  test "treats a hash between a marker and its number as punctuation" do
    assert_equal SequenceMarker.neutralize("Bleach Volume 2"), SequenceMarker.neutralize("Bleach Vol. #2")
    assert_equal [ "2" ], SequenceMarker.numbers("Bleach Vol. #2")
    assert_equal [ "2" ], SequenceMarker.numbers("Vol.#2")
  end

  test "requires a separator before a roman or spelled number on a full marker word" do
    assert_equal "Buchi neri", SequenceMarker.neutralize("Buchi neri")
    assert_empty SequenceMarker.numbers("Buchi neri")
    assert_empty SequenceMarker.numbers("parti")
    assert_empty SequenceMarker.numbers("volumeone")
    assert_equal [ "1" ], SequenceMarker.numbers("Buch i")
    assert_equal [ "1" ], SequenceMarker.numbers("Volume One")

    %w[T2 T.2 T02].each do |compact|
      assert_equal [ "2" ], SequenceMarker.numbers("Series #{compact}"), compact
      assert_equal SequenceMarker.neutralize("Series Volume 2"), SequenceMarker.neutralize("Series #{compact}"), compact
    end
    assert_equal [ "2" ], SequenceMarker.numbers("T.II")
    assert_equal [ "1" ], SequenceMarker.numbers("Vol.I")
  end

  test "rewrites a hyphenated part marker to the same volume as a spaced part" do
    assert_equal SequenceMarker.neutralize("Dune Part 2"), SequenceMarker.neutralize("Dune Part-2")
    assert_equal [ "2" ], SequenceMarker.numbers("Dune Part-2")
  end

  test "does not let an initials run complete a roman marker" do
    [
      "The Red Book C. G. Jung English EPUB",
      "The Red Book C.G. Jung English EPUB"
    ].each do |release|
      assert_empty SequenceMarker.numbers(release), release
      assert_not_includes SequenceMarker.neutralize(release), "100", release
    end

    assert_equal [ "100" ], SequenceMarker.numbers("Book C")
    assert_equal [ "2" ], SequenceMarker.numbers("Part 2. C. S. Lewis")
    assert_equal [ "4" ], SequenceMarker.numbers("Book IV. C. S. Lewis")
  end

  test "does not read a parenthesized publication year as a volume number" do
    [
      "Rudyard Kipling - The Jungle Book (1894) English EPUB",
      "The Jungle Book [1894]",
      "The Jungle Book ( 1894 )"
    ].each do |release|
      assert_empty SequenceMarker.numbers(release), release
      assert_equal release, SequenceMarker.neutralize(release), release
    end
  end

  test "keeps a possessive author inside the protected title" do
    protected_title = "William Shakespeare's Hamlet"
    author = "William Shakespeare"
    [
      "William Shakespeare's Hamlet - William Shakespeare English EPUB",
      "William Shakespeare’s Hamlet - William Shakespeare English EPUB",
      "William Shakespeares Hamlet - William Shakespeare English EPUB"
    ].each do |release|
      source = SequenceMarker.without_author_credit(
        release,
        author: author,
        protected_title: protected_title
      )

      assert_match(/\AWilliam Shakespeare['’]?s Hamlet\b/, source, release)
      assert_not_includes source, "Shakespeare English", release
    end
  end

  test "does not let author initials complete a marker in a release name" do
    release = "The Red Book C. G. Jung English EPUB"
    source = SequenceMarker.without_author_credit(
      release,
      author: "C. G. Jung",
      protected_title: "The Red Book"
    )

    assert_empty SequenceMarker.numbers(source)
    assert_not_includes SequenceMarker.neutralize(source), "100"
    assert_equal [ "2" ], SequenceMarker.numbers(
      SequenceMarker.without_author_credit(
        "The Red Book Volume 2 C. G. Jung English EPUB",
        author: "C. G. Jung",
        protected_title: "The Red Book Volume 2"
      )
    )
  end

  test "protects a title author when only the volume marker language differs" do
    source = SequenceMarker.without_author_credit(
      "The Collected Works of C. G. Jung Band 1 - C. G. Jung English EPUB",
      author: "C. G. Jung",
      protected_title: "The Collected Works of C. G. Jung Volume 1"
    )

    assert_includes source, "C. G. Jung Band 1"
    assert_not_includes source, "Jung English"
  end

  test "keeps curly apostrophe marker spans on character offsets" do
    title = "L\u2019Attaque des Titans Volume 2"

    assert_equal "L\u2019Attaque des Titans volume 2", SequenceMarker.neutralize(title)
    assert_equal "L\u2019Attaque des Titans 2", SequenceMarker.strip(title)
  end

  test "masks an abbreviated author after a multibyte character" do
    source = SequenceMarker.without_author_credit(
      "L\u2019\u00C9tranger C. Jung English EPUB",
      author: "C. G. Jung",
      protected_title: "L\u2019\u00C9tranger"
    )

    assert_includes source, "L\u2019\u00C9tranger"
    assert_not_includes source, "Jung"
  end

  test "keeps an abbreviated roman volume before a part label or release word" do
    release = "Les Miserables T. V Partie 1 - Victor Hugo French EPUB"

    assert_equal [ "5", "1" ], SequenceMarker.numbers(release)
    assert_not SequenceMarker.conflict?("Les Mis\u00E9rables Tome 5 Partie 1", release)
    assert_equal [ "5" ], SequenceMarker.numbers("Les Miserables T. V French EPUB")
    assert_equal [ "1", "1" ], SequenceMarker.numbers("Les Miserables T. I Partie 1")
    assert_empty SequenceMarker.numbers("T. C. Boyle Stories")
    assert_empty SequenceMarker.numbers("T C Boyle Stories")
  end

  test "keeps the author inside a title that ends on a roman volume" do
    protected_title = "The Collected Works of Carl Gustav Jung Volume I"
    source = SequenceMarker.without_author_credit(
      "The Collected Works of Carl Gustav Jung Volume I - Carl Gustav Jung English EPUB",
      author: "Carl Gustav Jung",
      protected_title: protected_title
    )

    assert_includes source, "Carl Gustav Jung Volume I"
    assert_not_includes source, "Jung English"
    assert_equal SequenceMarker.numbers(protected_title), SequenceMarker.numbers(source)
  end

  test "reads a roman volume before a novel subtitle" do
    release = "The Dark Tower Book V A Novel - Stephen King English EPUB"
    dotted = "The.Dark.Tower.Book.V.A.Novel.-.Stephen.King.English.EPUB"

    assert_equal [ "5" ], SequenceMarker.numbers("The Dark Tower Book V")
    assert_equal [ "5" ], SequenceMarker.numbers(release)
    assert_equal [ "5" ], SequenceMarker.numbers(dotted)
    assert_equal [ "5" ], SequenceMarker.numbers("The Dark Tower Book V A Novel")
    assert_equal [ "5" ], SequenceMarker.numbers("The Dark Tower Book V. A Novel")
    assert_empty SequenceMarker.numbers("The Red Book C. G. Jung English EPUB")
    assert_empty SequenceMarker.numbers("The Red Book C.G. Jung English EPUB")
  end

  test "masks an extra undotted middle initial before reading a roman marker" do
    source = SequenceMarker.without_author_credit(
      "The Red Book C G Jung English EPUB",
      author: "Carl Jung",
      protected_title: "The Red Book"
    )

    assert_not_includes source, "Jung"
    assert_empty SequenceMarker.numbers(source)
    assert_not_includes SequenceMarker.neutralize(source), "100"
  end

  test "reads an abbreviated roman volume before a language code" do
    release = "Victor.Hugo.-.Les.Miserables.T.V.FR.EPUB"

    assert_equal [ "5" ], SequenceMarker.numbers("Les Mis\u00E9rables T. V")
    assert_equal [ "5" ], SequenceMarker.numbers(release)
    assert_equal [ "5" ], SequenceMarker.numbers("Les Miserables T. V FR EPUB")
    assert_empty SequenceMarker.numbers("T. C. Boyle Stories")
    assert_empty SequenceMarker.numbers("T C Boyle Stories")
  end
end
