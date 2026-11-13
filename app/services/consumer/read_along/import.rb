# frozen_string_literal: true

require "digest"

# Imports a text/audio alignment for an EPUB and a separate audiobook that a
# tool (for example a forced aligner run on the server's own files) computed
# beforehand. Shelfarr never computes, estimates or interpolates timings.
#
# The document ("shelfarr-read-along" version 1, see docs/read-along.md) names
# the SHA-256 of the exact EPUB and of every audio file it was made from. An
# import succeeds only when those digests equal the library's current files,
# every cue names an element of a spine document and a valid, non-overlapping
# interval of one of those audio files. The alignment is then bound to the
# verified asset generations; when either changes it is reported as stale
# until `recheck` proves the bytes are still the same.
class Consumer::ReadAlong::Import
  class Invalid < StandardError; end

  FORMAT = "shelfarr-read-along"
  MAX_DOCUMENT_BYTES = 32.megabytes
  MAX_TRACKS = Consumer::ReadAlong::CueList::MAX_TRACKS
  MAX_TOOL_BYTES = 128
  DOCUMENT_KEYS = %w[format version tool ebook audio cues].freeze
  CUE_KEYS = %w[href fragment audio begin end].freeze
  DIGEST = /\A[0-9a-f]{64}\z/

  def initialize(ebook:, audiobook:, user: nil)
    @ebook = ebook
    @audiobook = audiobook
    @user = user
  end

  def call(document)
    raise Invalid, "Choose an ebook and an audiobook" unless @ebook.ebook? && @audiobook.audiobook?
    raise Invalid, "The alignment document is empty or larger than 32 MiB" unless document.is_a?(String) && document.bytesize.between?(1, MAX_DOCUMENT_BYTES)

    data = parse(document)
    epub = matching_epub(data.dig("ebook", "sha256"))
    tracks = matching_tracks(data["audio"])
    result = cues_for(epub, tracks.size, data["cues"])
    ReadAlongAlignment.transaction do
      alignment = ReadAlongAlignment.lock.find_or_initialize_by(ebook_book: @ebook)
      alignment.assign_attributes(audiobook_book: @audiobook, imported_by: @user, ebook_asset_id: epub[:asset].id,
        ebook_sha256: epub[:sha256], audio: tracks, document_sha256: Digest::SHA256.hexdigest(document),
        tool: data["tool"], cue_count: result.cues.size, coverage: result.coverage)
      alignment.payload = { "texts" => result.texts, "cues" => result.cues }
      alignment.save!
      alignment
    end
  end

  # After a file was moved, touched or re-imported by the library, its asset
  # generation changes. Rebind only if the bytes are provably the same.
  def self.recheck(alignment)
    import = new(ebook: alignment.ebook_book, audiobook: alignment.audiobook_book)
    epub = import.send(:matching_epub, alignment.ebook_sha256)
    tracks = import.send(:matching_tracks, alignment.audio.map { |track| track.slice("filename", "sha256") })
    alignment.update!(ebook_asset_id: epub[:asset].id, audio: tracks)
    alignment
  end

  private

  def parse(document)
    data = JSON.parse(document, max_nesting: 6)
    unless data.is_a?(Hash) && (data.keys - DOCUMENT_KEYS).empty? && data["format"] == FORMAT && data["version"] == 1
      raise Invalid, "This isn't a version 1 #{FORMAT} document"
    end
    tool = data["tool"]
    raise Invalid, "tool must be a short string" unless tool.nil? || (tool.is_a?(String) && tool.bytesize <= MAX_TOOL_BYTES && !tool.match?(/[\x00-\x1f]/))

    data
  rescue JSON::ParserError, JSON::NestingError, EncodingError
    raise Invalid, "The alignment document isn't valid JSON"
  end

  def matching_epub(digest)
    raise Invalid, "The document must name the EPUB's SHA-256" unless digest.is_a?(String) && digest.match?(DIGEST)

    assets = Consumer::LibraryAssets.new(@ebook, formats: %w[epub]).list
    assets.each do |asset|
      return { asset: asset, sha256: digest } if sha256(@ebook, asset) == digest
    end
    raise Invalid, "None of this ebook's EPUB files has the SHA-256 the alignment was made from"
  rescue Consumer::LibraryAssets::Unavailable => error
    raise Invalid, error.message
  end

  def matching_tracks(tracks)
    unless tracks.is_a?(Array) && tracks.size.between?(1, MAX_TRACKS) &&
        tracks.all? { |track| track.is_a?(Hash) && track.keys.sort == %w[filename sha256] && track["filename"].is_a?(String) && track["sha256"].to_s.match?(DIGEST) }
      raise Invalid, "audio must list each track's filename and SHA-256"
    end
    raise Invalid, "audio names a track twice" unless tracks.map { |track| track["filename"] }.uniq.size == tracks.size

    current = Consumer::LibraryAssets.new(@audiobook).list.group_by(&:filename)
    tracks.map do |track|
      matches = current.fetch(track["filename"], [])
      raise Invalid, "The audiobook has no single track named #{track["filename"].inspect}" unless matches.one?

      asset = matches.first
      raise Invalid, "#{track["filename"]} isn't the file the alignment was made from" unless sha256(@audiobook, asset) == track["sha256"]

      { "filename" => asset.filename, "sha256" => track["sha256"], "asset_id" => asset.id,
        "media_type" => asset.media_type, "size_bytes" => asset.size_bytes }
    end
  rescue Consumer::LibraryAssets::Unavailable => error
    raise Invalid, error.message
  end

  def cues_for(epub, track_count, cues)
    raise Invalid, "cues must be a list" unless cues.is_a?(Array) && cues.size.between?(1, Consumer::ReadAlong::CueList::MAX_CUES)

    asset, file = Consumer::LibraryAssets.new(@ebook, formats: %w[epub]).open(epub[:asset].id)
    raise Invalid, "The EPUB changed while importing" unless asset.id == epub[:asset].id

    package = Consumer::EpubPackage.open(file)
    index = Consumer::ReadAlong::TextIndex.new(package)
    list = Consumer::ReadAlong::CueList.new(index)
    cues.each do |cue|
      raise Invalid, "Each cue needs href, fragment, audio, begin and end" unless cue.is_a?(Hash) && cue.keys.sort == CUE_KEYS.sort
      unless cue["href"].is_a?(String) && cue["audio"].is_a?(Integer) && cue["audio"].between?(0, track_count - 1)
        raise Invalid, "A cue names an unknown text document or audio track"
      end

      list.add(path: cue["href"], fragment: cue["fragment"], audio: cue["audio"],
        begin_ms: milliseconds(cue["begin"]), end_ms: milliseconds(cue["end"]))
    end
    list.check!(track_count)
    Consumer::ReadAlong::Alignment.new(texts: list.texts, audio: [], cues: list.cues,
      coverage: index.coverage(list.aligned_paths, cue_count: list.cues.size, audio_ms: list.audio_ms))
  rescue Consumer::ReadAlong::CueList::Invalid, Consumer::EpubPackage::Invalid, Consumer::LibraryAssets::Unavailable => error
    raise Invalid, error.message
  ensure
    file&.close unless file&.closed?
  end

  # Seconds as a JSON number, to the nearest millisecond.
  def milliseconds(value)
    raise Invalid, "Cue times are seconds as numbers" unless value.is_a?(Numeric) && value.finite? && value >= 0

    (value * 1000).round
  end

  def sha256(book, asset)
    opened, file = Consumer::LibraryAssets.new(book, formats: %w[epub]).open(asset.id)
    raise Invalid, "#{asset.filename} changed while it was being checked" unless opened.id == asset.id

    digest = Digest::SHA256.new
    offset = 0
    while offset < asset.size_bytes
      chunk = file.pread([ 1.megabyte, asset.size_bytes - offset ].min, offset)
      digest << chunk
      offset += chunk.bytesize
    end
    raise Invalid, "#{asset.filename} changed while it was being checked" unless file.stat.size == asset.size_bytes

    digest.hexdigest
  rescue EOFError
    raise Invalid, "#{asset.filename} changed while it was being checked"
  ensure
    file&.close unless file&.closed?
  end
end
