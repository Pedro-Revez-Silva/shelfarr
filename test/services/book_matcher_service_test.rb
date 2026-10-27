# frozen_string_literal: true

require "test_helper"

class BookMatcherServiceTest < ActiveSupport::TestCase
  setup do
    @audiobook = Book.create!(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )

    @ebook = Book.create!(
      title: "Dune",
      author: "Frank Herbert",
      book_type: :ebook
    )
  end

  test "exact match returns high score" do
    result = BookMatcherService.match(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )

    assert result.exact?
    assert_equal @audiobook, result.book
    assert result.score >= 95
  end

  test "fuzzy match with slight typo" do
    result = BookMatcherService.match(
      title: "The Final Empre",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )

    assert result.fuzzy?
    assert_equal @audiobook, result.book
  end

  test "no match for different book type" do
    result = BookMatcherService.match(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      book_type: :ebook
    )

    assert result.no_match?
    assert_nil result.book
  end

  test "matches without author" do
    result = BookMatcherService.match(
      title: "Dune",
      author: nil,
      book_type: :ebook
    )

    assert_equal @ebook, result.book
  end

  test "find_or_create_book returns existing on match" do
    book = BookMatcherService.find_or_create_book(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )

    assert_equal @audiobook, book
  end

  test "find_or_create_book creates new when no match" do
    assert_difference "Book.count", 1 do
      book = BookMatcherService.find_or_create_book(
        title: "New Book",
        author: "New Author",
        book_type: :ebook
      )

      assert_equal "New Book", book.title
      assert_equal "New Author", book.author
      assert book.ebook?
    end
  end

  test "case insensitive matching" do
    result = BookMatcherService.match(
      title: "THE FINAL EMPIRE",
      author: "BRANDON SANDERSON",
      book_type: :audiobook
    )

    assert result.exact?
    assert_equal @audiobook, result.book
  end

  test "no match for completely different title" do
    result = BookMatcherService.match(
      title: "Completely Different Book",
      author: "Unknown Author",
      book_type: :audiobook
    )

    assert result.no_match?
  end

  test "returns no match for blank title" do
    result = BookMatcherService.match(
      title: "",
      author: "Some Author",
      book_type: :audiobook
    )

    assert result.no_match?
  end

  test "does not match different books in same series by same author" do
    existing_book = Book.create!(
      title: "Harry Potter und die Kammer des Schreckens (Die Harry-Potter-Buchreihe) (German Edition)",
      author: "J.K. Rowling",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Harry Potter und der Gefangene von Askaban (Die Harry-Potter-Buchreihe) (German Edition)",
      author: "J.K. Rowling",
      book_type: :ebook
    )

    assert result.no_match?, "Different books in the same series should not match (got #{result.match_type} with score #{result.score})"
    assert_nil result.book
  end

  test "does not match books with shared series suffix but different titles" do
    existing_book = Book.create!(
      title: "The Shadow Rising (The Wheel of Time Book 4)",
      author: "Robert Jordan",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "The Fires of Heaven (The Wheel of Time Book 5)",
      author: "Robert Jordan",
      book_type: :ebook
    )

    assert result.no_match?, "Different books in the same series should not match (got #{result.match_type} with score #{result.score})"
    assert_nil result.book
  end

  test "matches a complete title with a subtitle extension" do
    existing_book = Book.create!(
      title: "Project Hail Mary: A Novel",
      author: "Andy Weir",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Project Hail Mary",
      author: "Andy Weir",
      book_type: :ebook
    )

    assert result.fuzzy?
    assert_equal existing_book, result.book
  end

  test "matches an unseparated generic subtitle extension" do
    existing_book = Book.create!(
      title: "Project Hail Mary Novel",
      author: "Andy Weir",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Project Hail Mary",
      author: "Andy Weir",
      book_type: :ebook
    )

    assert result.fuzzy?
    assert_equal existing_book, result.book
  end

  test "normalizes ampersands as and" do
    existing_book = Book.create!(
      title: "War and Peace",
      author: "Leo Tolstoy",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "War & Peace",
      author: "Leo Tolstoy",
      book_type: :ebook
    )

    assert result.exact?
    assert_equal existing_book, result.book
  end

  test "matches a complete title after a series prefix" do
    existing_book = Book.create!(
      title: "Mistborn: The Final Empire",
      author: "Brandon Sanderson",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "The Final Empire",
      author: "Brandon Sanderson",
      book_type: :ebook
    )

    assert result.fuzzy?
    assert_equal existing_book, result.book
  end

  test "matches a complete title before a numbered series suffix" do
    existing_book = Book.create!(
      title: "The Fellowship of the Ring (The Lord of the Rings, Book 1)",
      author: "J.R.R. Tolkien",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "The Fellowship of the Ring",
      author: "J.R.R. Tolkien",
      book_type: :ebook
    )

    assert result.fuzzy?
    assert_equal existing_book, result.book
  end

  test "matches a short complete title before a generic subtitle" do
    existing_book = Book.create!(
      title: "The Martian: A Novel",
      author: "Andy Weir",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "The Martian",
      author: "Andy Weir",
      book_type: :ebook
    )

    assert result.fuzzy?
    assert_equal existing_book, result.book
  end

  test "matches a complete title before publisher edition metadata" do
    existing_book = Book.create!(
      title: "Pride and Prejudice: Penguin Classics",
      author: "Jane Austen",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Pride and Prejudice",
      author: "Jane Austen",
      book_type: :ebook
    )

    assert result.fuzzy?
    assert_equal existing_book, result.book
  end

  test "does not treat an unseparated sequel title as an alias" do
    Book.create!(
      title: "The Cat in the Hat Comes Back",
      author: "Dr. Seuss",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "The Cat in the Hat",
      author: "Dr. Seuss",
      book_type: :ebook
    )

    assert result.no_match?
    assert_nil result.book
  end

  test "does not treat a colon-delimited sequel subtitle as edition metadata" do
    Book.create!(
      title: "The Dark Tower: The Gunslinger",
      author: "Stephen King",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "The Dark Tower",
      author: "Stephen King",
      book_type: :ebook
    )

    assert result.no_match?
    assert_nil result.book
  end

  test "does not match a derivative title by the same credited author" do
    Book.create!(
      title: "Pride and Prejudice and Zombies",
      author: "Jane Austen",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Pride and Prejudice",
      author: "Jane Austen",
      book_type: :ebook
    )

    assert result.no_match?
    assert_nil result.book
  end

  test "does not match different numbered volumes" do
    Book.create!(
      title: "Attack on Titan Vol 2",
      author: "Hajime Isayama",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Attack on Titan Vol 1",
      author: "Hajime Isayama",
      book_type: :ebook
    )

    assert result.no_match?
    assert_nil result.book
  end

  test "matches equivalent volume marker formats" do
    existing_book = Book.create!(
      title: "Attack on Titan Volume 1",
      author: "Hajime Isayama",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Attack on Titan Vol. I",
      author: "Hajime Isayama",
      book_type: :ebook
    )

    assert result.exact?
    assert_equal existing_book, result.book
  end

  test "matches the same volume when the marker word is in another language" do
    existing_book = Book.create!(
      title: "The Witcher Part 2",
      author: "Andrzej Sapkowski",
      book_type: :ebook
    )
    baseline = BookMatcherService.match(
      title: "The Witcher Part 2",
      author: "Andrzej Sapkowski",
      book_type: :ebook
    )

    assert baseline.exact?
    [
      "The Witcher Tome 2",
      "The Witcher Partie 2",
      "The Witcher Livre 2",
      "The Witcher T2",
      "The Witcher T.2",
      "The Witcher T02",
      "The Witcher Band 2",
      "The Witcher Teil 2",
      "The Witcher Buch 2",
      "The Witcher Tomo 2",
      "The Witcher Parte 2",
      "The Witcher Libro 2",
      "The Witcher Livro 2",
      "The Witcher Volumen 2",
      "The Witcher Deel 2",
      "The Witcher Boek 2",
      "The Witcher Tome II",
      "The Witcher Part. 2",
      "The Witcher Volume 2",
      "The Witcher Book 2"
    ].each do |title|
      result = BookMatcherService.match(
        title: title,
        author: "Andrzej Sapkowski",
        book_type: :ebook
      )

      assert_equal baseline.score, result.score, title
      assert result.exact?, title
      assert_equal existing_book, result.book, title
    end
  end

  test "matches a split volume when both numbers agree across marker languages" do
    existing_book = Book.create!(
      title: "Chronicles of the Northern Sea Tome 3 Partie 1",
      author: "Ada Lovelace",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Chronicles of the Northern Sea Book 3 Part 1",
      author: "Ada Lovelace",
      book_type: :ebook
    )

    assert result.exact?, "got #{result.match_type} with score #{result.score}"
    assert_equal existing_book, result.book
  end

  test "does not match a different volume number when the marker language changes" do
    Book.create!(
      title: "The Illustrated Chronicles of the Northern Sea and Its Many Islands Book 2",
      author: "Ada Lovelace",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "The Illustrated Chronicles of the Northern Sea and Its Many Islands Tome 3",
      author: "Ada Lovelace",
      book_type: :ebook
    )

    assert result.no_match?, "got #{result.match_type} with score #{result.score}"
    assert_nil result.book
  end

  test "does not match pocket splits that share a tome and differ by part" do
    Book.create!(
      title: "Chronicles of the Northern Sea Tome 3 Partie 1",
      author: "Ada Lovelace",
      book_type: :ebook
    )

    result = BookMatcherService.match(
      title: "Chronicles of the Northern Sea Tome 3 Partie 2",
      author: "Ada Lovelace",
      book_type: :ebook
    )

    assert result.no_match?, "got #{result.match_type} with score #{result.score}"
    assert_nil result.book
  end

  test "does not treat an unnumbered marker word as a volume" do
    brothers = Book.create!(
      title: "Band of Brothers",
      author: "Stephen E. Ambrose",
      book_type: :ebook
    )
    parte = Book.create!(
      title: "La parte oscura del libro",
      author: "Mariana Enriquez",
      book_type: :ebook
    )

    brothers_match = BookMatcherService.match(
      title: "Band of Brothers",
      author: "Stephen E. Ambrose",
      book_type: :ebook
    )
    parte_match = BookMatcherService.match(
      title: "La parte oscura del libro",
      author: "Mariana Enriquez",
      book_type: :ebook
    )

    assert brothers_match.exact?
    assert_equal brothers, brothers_match.book
    assert parte_match.exact?
    assert_equal parte, parte_match.book
    assert BookMatcherService.match(
      title: "Tome 2",
      author: "Stephen E. Ambrose",
      book_type: :ebook
    ).no_match?
    assert BookMatcherService.match(
      title: "Libro 2",
      author: "Mariana Enriquez",
      book_type: :ebook
    ).no_match?
  end
end
