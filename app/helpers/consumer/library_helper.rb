# frozen_string_literal: true

module Consumer::LibraryHelper
  PDF_RESOURCE_ROOT = Rails.root.join("vendor/javascript")
  # PDF.js asks for these by kind and file name; the reader maps each name to
  # its digested asset so they work offline and never leave this server.
  PDF_RESOURCE_KINDS = { "cmaps" => "cMapUrl", "standard_fonts" => "standardFontDataUrl", "wasm" => "wasmUrl" }.freeze
  PDF_RESOURCES = PDF_RESOURCE_KINDS.keys.to_h do |folder|
    names = Dir.children(PDF_RESOURCE_ROOT.join("pdfjs", folder)).select { |name| name.match?(/\.(bcmap|pfb|ttf|wasm)\z/) }.sort
    [ folder, names.freeze ]
  end.freeze
  PDF_WORKER = "pdfjs/pdf.worker.js"

  # The worker and every resource it may need, as logical asset paths.
  def self.pdf_resource_paths
    [ PDF_WORKER, *PDF_RESOURCES.flat_map { |folder, names| names.map { |name| "pdfjs/#{folder}/#{name}" } } ]
  end

  def consumer_pdf_resources
    { worker: asset_path(PDF_WORKER),
      files: PDF_RESOURCES.to_h { |folder, names| [ PDF_RESOURCE_KINDS.fetch(folder), names.index_with { |name| asset_path("pdfjs/#{folder}/#{name}") } ] } }
  end

  def consumer_format_label(book, publication = nil)
    return "Audiobook" if book.audiobook?
    return "Comic" if book.comicbook? || book.content_graphic?

    formats = (publication&.dig(:assets) || []).map { |asset| asset[:format] }.uniq
    formats == [ "pdf" ] ? "PDF" : "Ebook"
  end
  def consumer_progress_label(publication)
    progress = publication[:progress]
    return "Files unavailable" if publication[:assets].empty?
    return "Finished" if publication[:reading_status] == "finished"
    return "Unread · saved place kept" if publication[:reading_status] == "unread" && progress
    return publication[:book_type] == "ebook" ? "Start reading" : "Start listening" unless progress
    page = progress.dig(:locator, "locations", "position")
    fixed = %w[application/pdf image/jpeg image/png image/webp].include?(progress.dig(:locator, "type"))
    return "New edition · start afresh" unless publication[:assets].any? { |asset| asset[:id] == progress[:asset_id] }
    return "Resume at #{consumer_time(progress[:position_seconds])}" if progress[:position_seconds]
    return "Page #{page}" if fixed && page.is_a?(Integer)

    percent = progress.dig(:locator, "locations", "totalProgression")
    percent ? "#{(percent * 100).round}% read" : "Continue reading"
  end

  def consumer_time(seconds)
    minutes, seconds = seconds.to_i.divmod(60)
    hours, minutes = minutes.divmod(60)
    hours.positive? ? format("%d:%02d:%02d", hours, minutes, seconds) : format("%d:%02d", minutes, seconds)
  end

  def consumer_cover_style(book)
    hash = book.id.to_s.bytes.reduce(0x811c9dc5) { |value, byte| ((value ^ byte) * 0x01000193) & 0xffffffff }
    [ "clay", "moss", "slate", "oat", "plum", "stone" ][hash % 6]
  end
end
