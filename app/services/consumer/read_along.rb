# frozen_string_literal: true

# Read-along for one EPUB asset generation: whether real text/audio alignment
# exists, and the manifest that lets a reader follow it.
#
# Two sources are real and nothing else is used:
#   media_overlay  EPUB 3 Media Overlays inside the book (its own SMIL and audio)
#   imported       an alignment imported for a separate audiobook, bound by
#                  SHA-256 to both files and then to their asset generations
#
# Chapter percentages, durations, text length and speech synthesis are never
# turned into timing. Statuses:
#   available  a validated manifest exists (coverage may still be partial)
#   unaligned  this edition has no alignment
#   stale      an imported alignment was made for an earlier file generation
#   invalid    alignment data exists but was refused (reason says why)
#
# The manifest is a separate resource bound to `generation`; it is not an
# ebook format and does not change how any client opens the EPUB.
class Consumer::ReadAlong
  VERSION = 1
  CUE_FIELDS = %w[text fragment audio begin_ms end_ms].freeze
  Alignment = Data.define(:texts, :audio, :cues, :coverage)
  Status = Data.define(:status, :source, :generation, :reason, :core, :audiobook)
  # Validated manifests can be large; refusals and "no overlay" are tiny and
  # keep library listings from reparsing every EPUB. Keys name an exact asset
  # generation (or imported alignment generation), so a hit is never stale.
  CACHE_LIMIT = 24
  SMALL_CACHE_LIMIT = 4096
  @cache = {}
  @small_cache = {}
  @cache_lock = Mutex.new

  class << self
    def for(book, asset)
      new(book, asset).status
    end

    def cached(key)
      @cache_lock.synchronize do
        store = [ @cache, @small_cache ].find { |candidate| candidate.key?(key) }
        next nil unless store

        value = store.delete(key)
        store[key] = value
      end
    end

    def remember(key, value)
      @cache_lock.synchronize do
        store, limit = value.is_a?(Status) && value.core.nil? ? [ @small_cache, SMALL_CACHE_LIMIT ] : [ @cache, CACHE_LIMIT ]
        store.delete(key)
        store[key] = value
        store.shift while store.size > limit
      end
      value
    end

    def forget_all
      @cache_lock.synchronize { @cache.clear && @small_cache.clear }
    end
  end

  def initialize(book, asset)
    @book = book
    @asset = asset
  end

  def status
    return unaligned unless @asset.format == "epub" && !@book.audiobook?

    imported_status || overlay_status
  end

  # The publication projection's short form.
  def self.summary(status, url:)
    value = { status: status.status }
    value[:source] = status.source if status.source
    value[:reason] = status.reason if status.reason
    if status.status == "available"
      coverage = status.core[:coverage]
      value.merge!(generation: status.generation, manifest_url: url,
        coverage: coverage.slice(:complete, :text_sections, :aligned_sections, :cues, :audio_ms),
        text_bytes: status.core[:resources_bytes], audio_bytes: status.core[:audio].sum { |track| track[:size_bytes].to_i })
    end
    value[:audiobook] = status.audiobook if status.audiobook
    value
  end

  private

  def unaligned(audiobook: same_work_audiobook)
    Status.new(status: "unaligned", source: nil, generation: nil, reason: nil, core: nil, audiobook: audiobook)
  end

  def refused(status, source, reason)
    Status.new(status: status, source: source, generation: nil, reason: reason, core: nil, audiobook: nil)
  end

  # An imported alignment for this ebook record. nil when it belongs to a
  # different, still-current EPUB of the same record.
  def imported_status
    alignment = ReadAlongAlignment.find_by(ebook_book_id: @book.id)
    return nil unless alignment

    if alignment.ebook_asset_id != @asset.id
      others = Consumer::LibraryAssets.new(@book, formats: %w[epub]).list.map(&:id)
      return nil if others.include?(alignment.ebook_asset_id)

      return refused("stale", "imported", "The EPUB changed after its read-along alignment was imported. An administrator can recheck it.")
    end

    audiobook = alignment.audiobook_book
    current = audiobook.acquired? ? Consumer::LibraryAssets.new(audiobook).list.index_by(&:id) : {}
    unless alignment.audio_asset_ids.all? { |id| current.key?(id) }
      return refused("stale", "imported", "The audiobook files changed after the alignment was imported. An administrator can recheck it.")
    end

    key = [ "imported", alignment.generation ]
    core = self.class.cached(key) || self.class.remember(key, imported_core(alignment))
    Status.new(status: "available", source: "imported", generation: alignment.generation, reason: nil, core: core,
      audiobook: { id: audiobook.id.to_s, title: audiobook.title })
  rescue Consumer::LibraryAssets::Unavailable
    refused("stale", "imported", "The audiobook this alignment uses is unavailable.")
  rescue ArgumentError, JSON::ParserError, Zlib::Error
    refused("invalid", "imported", "The stored alignment couldn't be read. Import it again.")
  end

  # The book's own Media Overlay, validated once per asset generation.
  def overlay_status
    key = [ "overlay", @asset.id ]
    cached = self.class.cached(key)
    return cached.status == "unaligned" ? unaligned : cached if cached

    result = inspect_overlay
    self.class.remember(key, result.status == "unaligned" ? result.with(audiobook: nil) : result)
    result
  end

  def inspect_overlay
    asset, file = Consumer::LibraryAssets.new(@book, formats: %w[epub]).open(@asset.id)
    package = Consumer::EpubPackage.open(file)
    return unaligned unless Consumer::ReadAlong::MediaOverlay.present?(package)

    alignment = Consumer::ReadAlong::MediaOverlay.new(package).call
    generation = Digest::SHA256.hexdigest([ "media_overlay", VERSION, asset.id ].join("\0"))
    audio = alignment.audio.map { |track| { kind: "epub_resource" }.merge(track) }
    Status.new(status: "available", source: "media_overlay", generation: generation, reason: nil,
      core: core(generation, "media_overlay", alignment.texts, audio, alignment.cues, alignment.coverage, package), audiobook: nil)
  rescue Consumer::ReadAlong::CueList::Invalid => error
    refused("invalid", "media_overlay", "This book's narration data can't be used: #{error.message}.")
  rescue Consumer::EpubPackage::Invalid
    # Without a safely readable package there is no known overlay to refuse.
    unaligned.with(reason: "This EPUB's archive couldn't be checked for narration (ZIP64 and other unusual archives aren't supported).")
  rescue Consumer::LibraryAssets::Unavailable
    refused("invalid", nil, "This EPUB is unavailable.")
  ensure
    file&.close unless file&.closed?
  end

  def imported_core(alignment)
    asset, file = Consumer::LibraryAssets.new(@book, formats: %w[epub]).open(@asset.id)
    raise Consumer::LibraryAssets::Unavailable unless asset.id == alignment.ebook_asset_id

    package = Consumer::EpubPackage.open(file)
    payload = alignment.payload
    audio = alignment.audio.map do |track|
      { kind: "publication_asset", publication_id: alignment.audiobook_book_id.to_s, asset_id: track.fetch("asset_id"),
        filename: track.fetch("filename"), media_type: track.fetch("media_type"), size_bytes: track.fetch("size_bytes") }
    end
    core(alignment.generation, "imported", payload.fetch("texts"), audio, payload.fetch("cues"),
      alignment.coverage.deep_symbolize_keys, package)
  ensure
    file&.close unless file&.closed?
  end

  # Route-free manifest content. `resources` lists every archive entry a
  # streaming reader may load for the text (never audio or overlays).
  def core(generation, source, texts, audio, cues, coverage, package)
    resources = [ Consumer::EpubPackage::CONTAINER, package.package_path ].map do |path|
      { href: path, media_type: package.media_type_of(path), size_bytes: package.entry(path).size }
    end
    package.items.each_value do |item|
      next unless item.size && package.servable?(item.path)
      next if Consumer::EpubPackage::AUDIO_TYPES.include?(item.media_type) || item.media_type == Consumer::EpubPackage::SMIL_TYPE
      next if item.media_type.start_with?("video/")

      resources << { href: item.path, media_type: item.media_type, size_bytes: item.size }
    end
    { version: VERSION, generation: generation, source: source, ebook_asset_id: @asset.id, package_path: package.package_path,
      text: texts.map { |path| { href: path, media_type: package.media_type_of(path) } },
      audio: audio, cue_fields: CUE_FIELDS, cues: cues, coverage: coverage, resources: resources,
      resources_bytes: resources.sum { |resource| resource[:size_bytes] } }
  end

  def same_work_audiobook
    ids = Book.work_ids_for(@book)
    return nil if ids.empty?

    audiobook = Book.find_by_any_work_id(ids, book_type: :audiobook)
    { id: audiobook.id.to_s, title: audiobook.title } if audiobook&.acquired?
  end
end
