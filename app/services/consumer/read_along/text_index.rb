# frozen_string_literal: true

# The element IDs and readable text of an EPUB's spine documents, so a cue's
# text target can be proven to exist in this exact generation and coverage
# can be stated honestly. Documents are parsed lazily, within per-document
# and total byte bounds, and never rendered.
class Consumer::ReadAlong::TextIndex
  MAX_TOTAL_BYTES = 96.megabytes
  MAX_FRAGMENT_BYTES = 256
  XHTML_NS = "http://www.w3.org/1999/xhtml"

  Document = Data.define(:path, :ids, :text)

  def initialize(package)
    @package = package
    @documents = {}
    @bytes = 0
    @spine_paths = package.spine_items.map(&:path).to_set
  end

  def spine_document?(path)
    @spine_paths.include?(path)
  end

  def document(path)
    @documents[path] ||= begin
      raise Consumer::EpubPackage::Invalid, "#{path} isn't a text document in this book's reading order" unless spine_document?(path)

      bytes = @package.read(path, limit: Consumer::EpubPackage::MAX_TEXT_BYTES)
      @bytes += bytes.bytesize
      raise Consumer::EpubPackage::Invalid, "This book's text is too large to align" if @bytes > MAX_TOTAL_BYTES

      xml = Consumer::EpubPackage.parse_xml(bytes, strict: false)
      ids = xml.xpath("//@id").map(&:value).to_set
      body = xml.at_xpath("//x:body", "x" => XHTML_NS) || xml.at_xpath("//*[local-name()='body']")
      Document.new(path: path, ids: ids, text: body.to_s.empty? ? false : body.text.match?(/[[:alnum:]]/))
    end
  end

  # Whether `fragment` names an element in the document at `path`.
  def element?(path, fragment)
    fragment.is_a?(String) && fragment.bytesize.between?(1, MAX_FRAGMENT_BYTES) &&
      !fragment.match?(/[\s\x00-\x1f]/) && document(path).ids.include?(fragment)
  end

  # Reading-order sections with readable text, and those of them with cues.
  def coverage(aligned_paths, cue_count:, audio_ms:)
    sections = @package.linear_spine_items.map(&:path).select { |path| document(path).text }
    aligned = sections.select { |path| aligned_paths.include?(path) }
    unaligned = sections - aligned
    { complete: unaligned.empty?, text_sections: sections.size, aligned_sections: aligned.size,
      unaligned_sections: unaligned.first(50), cues: cue_count, audio_ms: audio_ms }
  end
end
