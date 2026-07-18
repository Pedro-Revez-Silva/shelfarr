# frozen_string_literal: true

# Resolves Audible-owned titles against Shelfarr's canonical acquired books.
# Automatic links are deliberately conservative: only a stable ASIN-to-ISBN
# bridge may attach an Audible item to an acquired Shelfarr book. Matching
# title/author/narrator metadata is useful evidence, but it cannot distinguish
# an abridged, remastered, or otherwise different edition, so it is returned as
# a conflict and left for the administrator to back up separately.
class OwnedLibraryBookMatcher
  Resolution = Data.define(:book, :status, :source) do
    def matched?
      status == :matched
    end

    def conflict?
      status == :conflict
    end
  end

  def initialize(books: nil, library_items: nil)
    @books = books || Book.acquired.audiobooks.select(
      :id, :title, :author, :narrator, :isbn, :book_type, :file_path
    ).to_a
    @library_items = library_items || LibraryItem.available_for_matching
      .select(:asin, :isbn)
      .to_a
  end

  def resolve(item)
    identifier_resolution = resolve_by_identifier(item)
    return identifier_resolution if identifier_resolution

    title_candidates = item_titles(item).flat_map do |title|
      books_by_title.fetch(title, [])
    end.uniq
    return no_match if title_candidates.empty?

    metadata_candidates = title_candidates.select do |book|
      author_matches?(item, book) && narrator_matches?(item, book)
    end
    if metadata_candidates.one?
      return Resolution.new(book: nil, status: :conflict, source: :edition_collision)
    end

    if metadata_candidates.many? || title_candidates.any? { |book| identity_incomplete?(item, book) }
      Resolution.new(book: nil, status: :conflict, source: :title_collision)
    else
      no_match
    end
  end

  def resolve_many(items)
    Array(items).to_h { |item| [ item.id, resolve(item) ] }
  end

  private

  attr_reader :books, :library_items

  def resolve_by_identifier(item)
    asin = normalize_asin(item.external_id)
    return if asin.blank?

    isbns = library_isbns_by_asin.fetch(asin, [])
    return if isbns.empty?

    candidates = isbns.flat_map { |isbn| books_by_isbn.fetch(isbn, []) }.uniq
    return if candidates.empty?
    return Resolution.new(book: candidates.first, status: :matched, source: :isbn) if candidates.one?

    Resolution.new(book: nil, status: :conflict, source: :identifier_collision)
  end

  def books_by_title
    @books_by_title ||= books.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |book, index|
      title = normalize_text(book.title)
      index[title] << book if title.present?
    end
  end

  def books_by_isbn
    @books_by_isbn ||= books.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |book, index|
      isbn = normalize_isbn(book.isbn)
      index[isbn] << book if isbn.present?
    end
  end

  def library_isbns_by_asin
    @library_isbns_by_asin ||= library_items.each_with_object(
      Hash.new { |hash, key| hash[key] = [] }
    ) do |library_item, index|
      asin = normalize_asin(library_item.asin)
      isbn = normalize_isbn(library_item.isbn)
      next if asin.blank? || isbn.blank?

      index[asin] << isbn unless index[asin].include?(isbn)
    end
  end

  def item_titles(item)
    [ item.title, item.display_title ].filter_map do |title|
      normalize_text(title).presence
    end.uniq
  end

  def author_matches?(item, book)
    book_author = normalize_text(book.author)
    return false if book_author.blank?

    item_authors = Array(item.authors).filter_map do |author|
      normalize_text(author).presence
    end
    joined_authors = normalize_text(Array(item.authors).compact_blank.join(" "))
    item_authors.include?(book_author) ||
      (joined_authors.present? && joined_authors == book_author)
  end

  def narrator_matches?(item, book)
    book_narrator = normalize_text(book.narrator)
    item_narrators = Array(item.narrators).filter_map do |narrator|
      normalize_text(narrator).presence
    end
    return false if book_narrator.blank? || item_narrators.empty?

    joined_narrators = normalize_text(Array(item.narrators).compact_blank.join(" "))
    item_narrators.include?(book_narrator) || joined_narrators == book_narrator
  end

  def identity_incomplete?(item, book)
    normalized_authors(item).empty? || normalize_text(book.author).blank? ||
      normalized_narrators(item).empty? || normalize_text(book.narrator).blank?
  end

  def normalized_authors(item)
    Array(item.authors).filter_map { |author| normalize_text(author).presence }
  end

  def normalized_narrators(item)
    Array(item.narrators).filter_map { |narrator| normalize_text(narrator).presence }
  end

  def normalize_text(value)
    value.to_s
      .unicode_normalize(:nfkd)
      .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
      .downcase
      .gsub(/[^a-z0-9\s]/, " ")
      .gsub(/\s+/, " ")
      .strip
  end

  def normalize_asin(value)
    value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  def normalize_isbn(value)
    value.to_s.upcase.gsub(/[^0-9X]/, "")
  end

  def no_match
    Resolution.new(book: nil, status: :none, source: nil)
  end
end
