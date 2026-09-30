# frozen_string_literal: true

# Decides whether a planned library folder is a true collision.
# Ebook and audiobook copies of the same work may share one folder when the
# output root and path template are configured the same way. Different books
# that render to the same path still receive a numbered sibling folder.
class LibraryDestinationOccupancy
  AUDIO_EXTENSIONS = %w[
    aa aac aax aaxc aiff alac flac m4a m4b mp3 ogg opus wav wma
  ].freeze
  EBOOK_EXTENSIONS = %w[epub pdf mobi azw azw3 djvu].freeze
  COMIC_EXTENSIONS = %w[cbz cbr].freeze
  MAX_SCAN_DEPTH = 2

  class << self
    def occupied?(
      library_path:,
      book:,
      except_book_id: nil,
      except_upload_id: nil,
      except_import_id: nil
    )
      path = Pathname(library_path.to_s).expand_path
      return true if blocking_reservation?(
        path,
        except_upload_id: except_upload_id,
        except_import_id: except_import_id
      )
      return true if conflicting_acquired_book?(path, book, except_book_id: except_book_id)
      return false unless path_exists?(path)
      return true unless directory_without_symlink?(path)

      occupants = acquired_books_at(path, except_book_id: except_book_id)
      return false if occupants.any? && occupants.all? { |occupant| companion?(book, occupant) }

      contains_same_format_media?(path, book)
    end

    private

    def blocking_reservation?(path, except_upload_id:, except_import_id:)
      uploads = Upload.blocking_reservations.where(library_path: path.to_s)
      uploads = uploads.where.not(id: except_upload_id) if except_upload_id
      return true if uploads.exists?

      imports = OwnedMediaImport.blocking.where(library_path: path.to_s)
      imports = imports.where.not(id: except_import_id) if except_import_id
      imports.exists?
    end

    def conflicting_acquired_book?(path, book, except_book_id:)
      acquired_books_at(path, except_book_id: except_book_id).any? do |occupant|
        !companion?(book, occupant)
      end
    end

    def acquired_books_at(path, except_book_id:)
      scope = Book.acquired.where(file_path: path.to_s)
      scope = scope.where.not(id: except_book_id) if except_book_id
      scope.to_a
    end

    def companion?(book, occupant)
      complementary_types?(book, occupant) && same_work?(book, occupant)
    end

    def complementary_types?(left, right)
      [ left.book_type.to_s, right.book_type.to_s ].sort == %w[audiobook ebook]
    end

    def same_work?(left, right)
      left_ids = Book.work_ids_for(left)
      right_ids = Book.work_ids_for(right)
      return true if left_ids.any? && (left_ids & right_ids).any?
      return true if matching_isbn?(left, right)

      return false unless present_normalized_match?(left.title, right.title)
      return false unless present_normalized_match?(left.author, right.author)

      if left.series.present? && right.series.present?
        return false unless present_normalized_match?(left.series, right.series)
        if left.series_position.present? && right.series_position.present?
          return false unless normalize_series_position(left.series_position) ==
            normalize_series_position(right.series_position)
        end
      end

      true
    end

    def matching_isbn?(left, right)
      left_isbn = normalize_isbn(left.isbn)
      right_isbn = normalize_isbn(right.isbn)
      left_isbn.present? && left_isbn == right_isbn
    end

    def path_exists?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def directory_without_symlink?(path)
      File.directory?(path) && !File.symlink?(path)
    end

    def contains_same_format_media?(path, book)
      extensions = media_extensions_for(book)
      return false if extensions.empty?

      each_library_file(path) do |entry|
        extension = File.extname(entry).delete_prefix(".").downcase
        return true if extensions.include?(extension)
      end
      false
    end

    def media_extensions_for(book)
      if book.audiobook?
        AUDIO_EXTENSIONS
      elsif book.comicbook?
        COMIC_EXTENSIONS
      else
        EBOOK_EXTENSIONS
      end
    end

    def each_library_file(path, depth = 0, &block)
      return if depth > MAX_SCAN_DEPTH

      Dir.children(path).each do |name|
        next if name.start_with?(".")

        child = File.join(path, name)
        next if File.symlink?(child)

        if File.directory?(child)
          each_library_file(child, depth + 1, &block)
        elsif File.file?(child)
          yield child
        end
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
      nil
    end

    def present_normalized_match?(left, right)
      normalized_left = normalized_text(left)
      normalized_right = normalized_text(right)
      normalized_left.present? && normalized_left == normalized_right
    end

    def normalized_text(value)
      value.to_s
        .unicode_normalize(:nfkc)
        .downcase(:fold)
        .gsub(/[^[:alnum:]]+/, " ")
        .squish
    end

    def normalize_series_position(value)
      text = value.to_s.strip
      return text if text.blank?

      text.sub(/\A0+(?=\d)/, "")
    end

    def normalize_isbn(value)
      value.to_s.upcase.gsub(/[^0-9X]/, "")
    end
  end
end
