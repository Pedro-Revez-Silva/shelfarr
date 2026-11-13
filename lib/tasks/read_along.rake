# frozen_string_literal: true

# Administration of imported read-along alignments (docs/read-along.md).
#
#   bin/rails "read_along:import[EBOOK_ID,AUDIOBOOK_ID,/path/to/alignment.json]"
#   bin/rails "read_along:recheck[EBOOK_ID]"
#   bin/rails "read_along:remove[EBOOK_ID]"
#   bin/rails read_along:list
#
# Imports never compute timing; they verify a document produced elsewhere
# against the exact files in the library.
namespace :read_along do
  desc "Import a shelfarr-read-along alignment for an ebook and a separate audiobook"
  task :import, %i[ebook_id audiobook_id path] => :environment do |_task, args|
    ebook = Book.find(args.fetch(:ebook_id))
    audiobook = Book.find(args.fetch(:audiobook_id))
    path = args.fetch(:path)
    size = File.size(path)
    abort "The alignment document is larger than 32 MiB" if size > Consumer::ReadAlong::Import::MAX_DOCUMENT_BYTES

    alignment = Consumer::ReadAlong::Import.new(ebook: ebook, audiobook: audiobook).call(File.binread(path, size))
    coverage = alignment.coverage
    puts "Imported #{alignment.cue_count} cues for “#{ebook.title}” with “#{audiobook.title}”: " \
      "#{coverage["aligned_sections"]} of #{coverage["text_sections"]} text sections narrated."
  rescue Consumer::ReadAlong::Import::Invalid, ActiveRecord::RecordNotFound, KeyError, SystemCallError => error
    abort "Not imported: #{error.message}"
  end

  desc "Rebind an imported alignment after its files moved, if their bytes are unchanged"
  task :recheck, %i[ebook_id] => :environment do |_task, args|
    alignment = ReadAlongAlignment.find_by!(ebook_book_id: args.fetch(:ebook_id))
    Consumer::ReadAlong::Import.recheck(alignment)
    puts "The alignment for “#{alignment.ebook_book.title}” matches the current files."
  rescue Consumer::ReadAlong::Import::Invalid, ActiveRecord::RecordNotFound, KeyError => error
    abort "Still stale: #{error.message}"
  end

  desc "Remove an imported alignment"
  task :remove, %i[ebook_id] => :environment do |_task, args|
    count = ReadAlongAlignment.where(ebook_book_id: args.fetch(:ebook_id)).delete_all
    puts count.zero? ? "No imported alignment for that ebook." : "Removed the imported alignment."
  end

  desc "List imported alignments and whether they are current"
  task list: :environment do
    ReadAlongAlignment.includes(:ebook_book, :audiobook_book).find_each do |alignment|
      book = alignment.ebook_book
      asset = Consumer::LibraryAssets.new(book, formats: %w[epub]).list.find { |candidate| candidate.id == alignment.ebook_asset_id } ||
        Consumer::LibraryAssets.new(book, formats: %w[epub]).list.first
      status = asset ? Consumer::ReadAlong.for(book, asset).status : "unavailable"
      puts "#{book.id}\t#{status}\t#{alignment.cue_count} cues\t#{book.title} ↔ #{alignment.audiobook_book.title}"
    rescue Consumer::LibraryAssets::Unavailable
      puts "#{book.id}\tunavailable\t#{book.title}"
    end
  end
end
