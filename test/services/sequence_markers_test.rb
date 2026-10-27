# frozen_string_literal: true

require "test_helper"

class SequenceMarkersTest < ActiveSupport::TestCase
  MARKER_WORDS = %w[
    book part vol volume
    tome partie livre
    band teil buch
    tomo parte libro livro volumen
    deel boek
  ].freeze

  test "rewrites one numbered marker from any supported language to the same volume" do
    assert_equal MARKER_WORDS, SequenceMarkers::WORDS

    expected = "Series volume 2"
    MARKER_WORDS.each do |word|
      assert_equal expected, SequenceMarkers.normalize("Series #{word} 2"), word
      assert_equal expected, SequenceMarkers.normalize("Series #{word}. 2"), word
    end
    %w[T2 T.2 T02].each do |compact|
      assert_equal expected, SequenceMarkers.normalize("Series #{compact}"), compact
    end
    assert_equal "Series volume 2", SequenceMarkers.normalize("Series Vol. II")
    assert_equal "Series volume 2", SequenceMarkers.normalize("Series Part Two")
    assert_equal "Series volume 2", SequenceMarkers.normalize("Series Tome 02")
  end

  test "keeps two markers ordered so only the numbers can conflict" do
    assert_equal "Dune volume 3 part 1", SequenceMarkers.normalize("Dune Tome 3 Partie 1")
    assert_equal "Dune volume 3 part 1", SequenceMarkers.normalize("Dune Book 3 Part 1")
    assert_equal "Dune volume 3 part 2", SequenceMarkers.normalize("Dune Tome 3 Partie 2")

    assert SequenceMarkers.conflict?("Dune Tome 3 Partie 1", "Dune Tome 3 Partie 2")
    assert SequenceMarkers.conflict?("Attack on Titan Book 2", "Attack on Titan Book 3")
    assert_not SequenceMarkers.conflict?("Dune Tome 3 Partie 1", "Dune Book 3 Part 1")
    assert_not SequenceMarkers.conflict?("Series Part 2", "Series Tome 2")
    assert_not SequenceMarkers.conflict?("Series Tome 3", "Series Tome 3 Partie 1")
  end

  test "does not treat a marker word as a marker unless a number follows it" do
    assert_equal "Band of Brothers", SequenceMarkers.normalize("Band of Brothers")
    assert_equal "la parte mas importante", SequenceMarkers.normalize("la parte mas importante")
    assert_equal "la parte civil", SequenceMarkers.normalize("la parte civil")
    assert_equal "parte mix", SequenceMarkers.normalize("parte mix")
    assert_equal "tome dix", SequenceMarkers.normalize("tome dix")

    assert_equal "Band of Brothers", SequenceMarkers.strip("Band of Brothers")
    assert_equal "la parte civil", SequenceMarkers.strip("la parte civil")
    assert_equal "Series 2", SequenceMarkers.strip("Series Tome 2")
    assert_equal "Series 2", SequenceMarkers.strip("Series Part 2")
  end
end
