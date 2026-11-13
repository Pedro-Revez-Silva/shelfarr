# frozen_string_literal: true

# Validated read-along cues from either source. A cue names an element of
# one text document and an interval of one audio resource:
#
#   [text_index, fragment, audio_index, begin_ms, end_ms]
#
# end_ms is nil only when the source says "to the end of the audio" (an EPUB
# clip without clipEnd); such a cue must be the last one on its audio. Within
# one audio resource cues may not overlap. Nothing is interpolated: a cue
# exists only because the source names both its text and its interval.
class Consumer::ReadAlong::CueList
  class Invalid < StandardError; end

  MAX_CUES = 200_000
  MAX_TRACKS = 2_000
  # Rounded clip values in real overlays can touch; real overlap cannot.
  OVERLAP_TOLERANCE_MS = 5

  attr_reader :texts, :cues

  def initialize(index)
    @index = index
    @texts = []
    @text_positions = {}
    @cues = []
  end

  def add(path:, fragment:, audio:, begin_ms:, end_ms:)
    raise Invalid, "This alignment has more than #{MAX_CUES} cues" if @cues.size >= MAX_CUES
    raise Invalid, "A cue's text target #{path}##{fragment} isn't in this book" unless @index.element?(path, fragment)
    unless begin_ms.is_a?(Integer) && begin_ms.between?(0, Consumer::ReadAlong::Clock::MAX_MS) &&
        (end_ms.nil? || (end_ms.is_a?(Integer) && end_ms > begin_ms && end_ms <= Consumer::ReadAlong::Clock::MAX_MS))
      raise Invalid, "A cue for #{path}##{fragment} has an invalid interval"
    end

    text = (@text_positions[path] ||= (@texts << path).size - 1)
    @cues << [ text, fragment, audio, begin_ms, end_ms ]
  end

  # Per audio resource, intervals sorted by start must not overlap, and an
  # open-ended cue must be the last.
  def check!(audio_count)
    unless audio_count.is_a?(Integer) && audio_count.between?(1, MAX_TRACKS)
      raise Invalid, "This alignment must have between 1 and #{MAX_TRACKS} audio tracks"
    end
    raise Invalid, "This alignment has no cues" if @cues.empty?

    @cues.group_by { |cue| cue[2] }.each do |audio, cues|
      raise Invalid, "A cue names audio that isn't in this alignment" unless audio.is_a?(Integer) && audio.between?(0, audio_count - 1)

      sorted = cues.sort_by { |cue| cue[3] }
      sorted.each_cons(2) do |previous, following|
        raise Invalid, "A cue without an end isn't the last on its audio" if previous[4].nil?
        raise Invalid, "Two cues overlap in the same audio" if following[3] < previous[4] - OVERLAP_TOLERANCE_MS
      end
    end
    order_by_text
    self
  end

  def aligned_paths
    @texts.to_set
  end

  def audio_ms
    @cues.sum { |cue| cue[4] ? cue[4] - cue[3] : 0 }
  end

  private

  def order_by_text
    @cues.sort_by! { |cue| [ *@index.reading_order(@texts.fetch(cue[0]), cue[1]), cue[2], cue[3] ] }
    paths = @texts
    @texts = []
    @text_positions = {}
    @cues.each do |cue|
      path = paths.fetch(cue[0])
      cue[0] = (@text_positions[path] ||= (@texts << path).size - 1)
    end
  end
end
