# frozen_string_literal: true

require "test_helper"

class SequenceMarkerTest < ActiveSupport::TestCase
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
end
