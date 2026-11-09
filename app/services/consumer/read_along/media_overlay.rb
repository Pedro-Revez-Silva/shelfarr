# frozen_string_literal: true

# Read-along cues from an EPUB 3 Media Overlay already inside the book
# (https://www.w3.org/TR/epub-33/#sec-media-overlays): each spine document's
# manifest item names a SMIL document through `media-overlay`, and each SMIL
# <par> pairs a <text src="chapter.xhtml#id"> with an
# <audio src="audio.mp3" clipBegin=… clipEnd=…>.
#
# Only overlays whose every reference resolves inside this exact EPUB are
# accepted: text targets must be elements of spine documents, audio must be a
# present manifest item of an audio type, and clip intervals must be valid
# and non-overlapping. Any failure refuses the whole overlay, so a damaged one
# never highlights the wrong words.
class Consumer::ReadAlong::MediaOverlay
  MAX_SMIL_BYTES = 8.megabytes
  MAX_TOTAL_SMIL_BYTES = 64.megabytes
  SMIL_NS = "http://www.w3.org/ns/SMIL"

  def self.present?(package)
    package.spine_items.any?(&:media_overlay)
  end

  def initialize(package)
    @package = package
  end

  def call
    index = Consumer::ReadAlong::TextIndex.new(@package)
    cues = Consumer::ReadAlong::CueList.new(index)
    audio = []
    audio_positions = {}
    total = 0
    @package.spine_items.select(&:media_overlay).map(&:media_overlay).uniq.each do |overlay_id|
      overlay = @package.items[overlay_id]
      unless overlay && overlay.media_type == Consumer::EpubPackage::SMIL_TYPE && @package.entry(overlay.path)
        raise Consumer::ReadAlong::CueList::Invalid, "A media overlay named by the book is missing"
      end

      bytes = @package.read(overlay.path, limit: MAX_SMIL_BYTES)
      total += bytes.bytesize
      raise Consumer::ReadAlong::CueList::Invalid, "This book's media overlays are too large" if total > MAX_TOTAL_SMIL_BYTES

      smil = Consumer::EpubPackage.parse_xml(bytes)
      raise Consumer::ReadAlong::CueList::Invalid, "#{overlay.path} isn't a SMIL document" unless smil.root&.name == "smil" && smil.root.namespace&.href == SMIL_NS

      smil.xpath("//s:par", "s" => SMIL_NS).each do |par|
        text = par.at_xpath("s:text", "s" => SMIL_NS)
        clip = par.at_xpath("s:audio", "s" => SMIL_NS)
        raise Consumer::ReadAlong::CueList::Invalid, "A media overlay cue has no text" unless text
        # A text-only <par> has no narration to follow.
        next unless clip

        path, fragment = @package.resolve(text["src"].to_s, from: overlay.path, fragment: true)
        raise Consumer::ReadAlong::CueList::Invalid, "A media overlay names text outside this book" unless path

        audio_path = @package.resolve(clip["src"].to_s, from: overlay.path)
        item = audio_path && @package.item_at(audio_path)
        unless item && Consumer::EpubPackage::AUDIO_TYPES.include?(item.media_type) && @package.entry(audio_path)
          raise Consumer::ReadAlong::CueList::Invalid, "A media overlay names audio that isn't in this book"
        end
        raise Consumer::ReadAlong::CueList::Invalid, "Narration audio exceeds 2 GiB" if item.size > Consumer::EpubPackage::MAX_AUDIO_BYTES

        position = audio_positions[audio_path] ||= begin
          audio << { href: audio_path, media_type: item.media_type, size_bytes: item.size }
          audio.size - 1
        end
        begin_ms = clip["clipBegin"] ? Consumer::ReadAlong::Clock.milliseconds(clip["clipBegin"]) : 0
        end_ms = clip["clipEnd"] ? Consumer::ReadAlong::Clock.milliseconds(clip["clipEnd"]) : nil
        cues.add(path: path, fragment: fragment, audio: position, begin_ms: begin_ms, end_ms: end_ms)
      end
    end
    cues.check!(audio.size)
    Consumer::ReadAlong::Alignment.new(texts: cues.texts, audio: audio, cues: cues.cues,
      coverage: index.coverage(cues.aligned_paths, cue_count: cues.cues.size, audio_ms: cues.audio_ms))
  rescue Consumer::ReadAlong::Clock::Invalid, Consumer::EpubPackage::Invalid => error
    # The package opened; what failed is the overlay or a document it names.
    raise Consumer::ReadAlong::CueList::Invalid, error.message
  end
end
