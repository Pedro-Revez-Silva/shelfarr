# frozen_string_literal: true

require "zlib"

# An imported alignment between one EPUB and the separate audiobook files it
# was computed from (see Consumer::ReadAlong::Import). It is usable only while
# both asset generations it was verified against are still current.
class ReadAlongAlignment < ApplicationRecord
  MAX_CUE_BYTES = 64.megabytes

  belongs_to :ebook_book, class_name: "Book"
  belongs_to :audiobook_book, class_name: "Book"
  belongs_to :imported_by, class_name: "User", optional: true

  validates :ebook_asset_id, :ebook_sha256, :document_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :cue_count, numericality: { only_integer: true, greater_than: 0 }

  def audio_asset_ids
    audio.map { |track| track.fetch("asset_id") }
  end

  # { "texts" => [...], "cues" => [[text, fragment, audio, begin_ms, end_ms], ...] }
  def payload
    data = Zlib::GzipReader.new(StringIO.new(cues_gzip)).read(MAX_CUE_BYTES + 1)
    raise ArgumentError, "Stored read-along cues are too large" if data.to_s.bytesize > MAX_CUE_BYTES

    JSON.parse(data.to_s, max_nesting: 4)
  end

  def payload=(value)
    io = StringIO.new(+"".b)
    gzip = Zlib::GzipWriter.new(io)
    gzip.write(JSON.generate(value))
    gzip.close
    self.cues_gzip = io.string
  end

  # Changes whenever the alignment, its source document or either bound
  # asset generation does, so clients and offline copies can tell.
  def generation
    Digest::SHA256.hexdigest([ "imported", id, document_sha256, ebook_asset_id, *audio_asset_ids, updated_at&.utc&.iso8601(6) ].join("\0"))
  end
end
