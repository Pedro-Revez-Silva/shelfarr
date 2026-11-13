# frozen_string_literal: true

class DuplicateDetectionService
  ALLOW = :allow
  WARN = :warn
  BLOCK = :block           # Exact duplicate, cannot create
  # A colon can introduce either edition boilerplate ("A Novel") or a different
  # work ("Dune: The Duke of Caladan"). Only the boilerplate is safe to drop.
  EDITION_WORDS = %w[
    a an the abridged anniversary audiobook biography book classic classics
    collection deluxe ebook edition illustrated memoir novel novella part
    revised series special unabridged updated vol volume
  ].freeze
  PARTICLES = %w[al bin da das de del della den der di dos du la le st ten ter van von].freeze
  APOSTROPHE = /['\u2019\u2018\u02BC\u00B4]/
  PARENTHETICAL = /\([^)]*\)|\[[^\]]*\]/
  SUBTITLE_SEPARATOR = /\s*(?::|;|\u2013|\u2014|\s-\s)\s*/
  AUTHOR_SEPARATOR = /\s*(?:&|\/)\s*|\s*;\s*|\s+\b(?:and|with)\b\s+/i
  NAME_SUFFIX = /\b(?:jr|sr|ii|iii|iv|ph\.?d|m\.?d)\b\.?/i
  AuthorName = Data.define(:surname, :given_names)
  private_constant :EDITION_WORDS, :PARTICLES, :APOSTROPHE, :PARENTHETICAL,
    :SUBTITLE_SEPARATOR, :AUTHOR_SEPARATOR, :NAME_SUFFIX, :AuthorName

  Result = Data.define(:status, :message, :existing_book, :existing_request) do
    def allow?
      status == ALLOW
    end

    def warn?
      status == WARN
    end

    def block?
      status == BLOCK
    end
  end

  class << self
    def check(work_id:, edition_id: nil, book_type:, source_work_ids: nil, existing_books_lookup: nil, title: nil, author: nil)
      book_type = book_type.to_s
      work_ids = [ work_id, *Array(source_work_ids) ].compact_blank.uniq

      if edition_id.present?
        existing = Book.find_by(open_library_edition_id: edition_id, book_type: book_type)
        if existing&.acquired?
          return Result.new(
            status: BLOCK,
            message: "This exact edition is already in your library.",
            existing_book: existing,
            existing_request: nil
          )
        end
      end

      existing_book = find_existing_book(work_ids, book_type: book_type, existing_books_lookup: existing_books_lookup)
      # Work ids stay inside one metadata provider. An acquired Hardcover copy
      # therefore cannot block an Open Library or Google Books candidate until
      # the title and author are compared for this format alone.
      existing_book ||= find_acquired_by_identity(
        title: title,
        author: author,
        book_type: book_type,
        existing_books_lookup: existing_books_lookup
      )
      if existing_book&.acquired?
        return Result.new(
          status: BLOCK,
          message: "This #{label_for(book_type)} is already in your library.",
          existing_book: existing_book,
          existing_request: nil
        )
      end

      if existing_book
        active_request = existing_book.requests.open.first
        if active_request
          return Result.new(
            status: BLOCK,
            message: "This #{label_for(book_type)} already has an active request.",
            existing_book: existing_book,
            existing_request: active_request
          )
        end
      end

      # Check 4: Same work exists as different type (warn only)
      other_books = (Book.book_types.keys - [ book_type ]).filter_map do |other_type|
        book = find_existing_book(work_ids, book_type: other_type, existing_books_lookup: existing_books_lookup)
        [ other_type, book ] if book
      end
      if other_books.any?
        other_type, other_book = other_books.first
        return Result.new(
          status: WARN,
          message: "This title exists as #{label_with_article(other_type)}. You can still request the #{label_for(book_type)}.",
          existing_book: other_book,
          existing_request: nil
        )
      end

      # Check 5: Same work has a failed/not_found request (warn, allow retry)
      if existing_book
        failed_request = existing_book.requests.where(status: [ :failed, :not_found ]).first
        if failed_request
          return Result.new(
            status: WARN,
            message: "A previous request for this #{label_for(book_type)} #{failed_request.failed? ? 'failed' : 'was not found'}. You can try again.",
            existing_book: existing_book,
            existing_request: failed_request
          )
        end
      end

      Result.new(
        status: ALLOW,
        message: nil,
        existing_book: existing_book,
        existing_request: nil
      )
    end

    def can_request?(work_id:, edition_id: nil, book_type:, source_work_ids: nil, existing_books_lookup: nil, title: nil, author: nil)
      result = check(
        work_id: work_id,
        edition_id: edition_id,
        book_type: book_type,
        source_work_ids: source_work_ids,
        existing_books_lookup: existing_books_lookup,
        title: title,
        author: author
      )
      !result.block?
    end

    def find_existing_book(work_ids, book_type:, existing_books_lookup: nil)
      if existing_books_lookup.present?
        Book.find_in_lookup(existing_books_lookup, work_ids, book_type: book_type)
      else
        Book.find_by_any_work_id(work_ids, book_type: book_type)
      end
    end

    def label_with_article(book_type)
      label = label_for(book_type)
      article = label.match?(/\A[aeiou]/i) ? "an" : "a"
      "#{article} #{label}"
    end

    def label_for(book_type)
      return "Comics & Manga title" if book_type.to_s == "comicbook"

      RequestOptionPolicy.book_type_label(book_type).downcase
    end

    private

    def find_acquired_by_identity(title:, author:, book_type:, existing_books_lookup:)
      return if title.blank? || author.blank?

      candidate_forms = title_forms(title)
      candidate_names = author_names(author)
      return if candidate_forms.empty? || candidate_names.empty?

      acquired_books(book_type, existing_books_lookup).find do |book|
        same_work_title?(title, book.title, candidate_forms) &&
          same_author?(candidate_names, author_names(book.author))
      end
    end

    # One library scan is reused by every search card that shares a lookup.
    def acquired_books(book_type, lookup)
      key = book_type.to_s
      cache = acquired_book_cache(lookup)
      return cache[key] if cache.key?(key)

      cache[key] = Book.acquired.where(book_type: key).to_a
    end

    def acquired_book_cache(lookup)
      return {} unless lookup

      lookup.instance_variable_get(:@acquired_title_cache) ||
        lookup.instance_variable_set(:@acquired_title_cache, {})
    end

    def same_work_title?(candidate_title, book_title, candidate_forms)
      return false if SequenceMarker.conflict?(candidate_title, book_title)

      candidate_forms.intersect?(title_forms(book_title))
    end

    def title_forms(title)
      raw = title.to_s
      forms = [ normalized_title(raw) ]
      notes = raw.scan(PARENTHETICAL)
      if notes.any? && notes.all? { |note| edition_suffix?(note) }
        forms << normalized_title(raw.gsub(PARENTHETICAL, " "))
      end

      head, tail = raw.split(SUBTITLE_SEPARATOR, 2)
      forms << normalized_title(head) if tail.present? && edition_suffix?(tail)
      forms.compact_blank.uniq
    end

    def edition_suffix?(text)
      words = normalized_title(text).split
      return false if words.empty?
      return false if words.intersect?(%w[and or versus vs])

      words.all? { |word| EDITION_WORDS.include?(word) }
    end

    def same_author?(left_names, right_names)
      return false if left_names.empty? || right_names.empty?

      left_names.any? do |left_name|
        right_names.any? { |right_name| same_person?(left_name, right_name) }
      end
    end

    # A shared surname still leaves "Frank Herbert" and "Brian Herbert" apart
    # when both sides include a given name.
    def same_person?(left, right)
      return false unless left.surname == right.surname
      return true if left.given_names.empty? || right.given_names.empty?

      left.given_names.intersect?(right.given_names)
    end

    def author_names(author)
      return [] if author.blank?

      people_from(author.to_s.gsub(NAME_SUFFIX, " ")).filter_map { |person| author_name_for(person) }.uniq
    end

    def people_from(author)
      author.split(AUTHOR_SEPARATOR).flat_map { |segment| people_in_segment(segment) }
    end

    def people_in_segment(segment)
      parts = segment.split(",").map(&:squish).compact_blank
      return [] if parts.empty?
      return [ natural_person(parts[0]) ] if parts.one?
      return [ inverted_person(parts[0], parts[1]) ] if parts.size == 2 && !natural_order_pair?(parts[0], parts[1])
      return paired_people(parts) if parts.size > 2 && parts.any? { |part| significant_tokens(part).size < 2 }

      parts.map { |part| natural_person(part) }
    end

    def natural_order_pair?(left, right)
      left_tokens = significant_tokens(left)
      right_tokens = significant_tokens(right)
      return false unless left_tokens.size >= 2 && right_tokens.size >= 2
      return false if PARTICLES.include?(left_tokens.first) && left_tokens.size == 2

      true
    end

    def paired_people(parts)
      parts.each_slice(2).map { |surname, given| inverted_person(surname, given) }
    end

    def natural_person(name)
      { natural: true, name: name }
    end

    def inverted_person(surname, given)
      { natural: false, surname: surname, given: given }
    end

    def author_name_for(person)
      if person[:natural]
        tokens = significant_tokens(person[:name])
        return if tokens.empty?

        AuthorName.new(surname: tokens.last, given_names: tokens[0...-1])
      else
        surname = significant_tokens(person[:surname]).last
        return if surname.blank?

        AuthorName.new(surname: surname, given_names: significant_tokens(person[:given]))
      end
    end

    def significant_tokens(value)
      tokens = normalized_text(value).split.reject { |token| token.length < 2 }
      without_particles = tokens.reject { |token| PARTICLES.include?(token) }
      without_particles.presence || tokens
    end

    def normalized_title(value)
      normalized_text(value).sub(/\A(?:the|a|an)\s+/, "")
    end

    def normalized_text(value)
      value.to_s
        .unicode_normalize(:nfkd)
        .gsub(APOSTROPHE, "")
        .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
        .downcase
        .gsub("&", " and ")
        .gsub(/[^a-z0-9\s]/, " ")
        .squish
    end
  end
end
