# frozen_string_literal: true

module Kobo
  # The real Kobo sentence markers of one chapter of a delivered KEPUB.
  #
  # Kobo's KEPUB renderer names a reading place by chapter resource plus the id
  # of a <span class="koboSpan" id="kobo.P.S"> that exists in that chapter.
  # This index only ever returns such an id read from the exact bytes Shelfarr
  # delivered; it never constructs one. A Shelfarr place is placed on the span
  # that contains it, measured in characters of body text:
  #
  # * an EPUB CFI saved by the web reader for this same file, when it resolves
  #   to a node of this chapter;
  # * otherwise a fragment id naming one element of the chapter;
  # * otherwise the chapter progression, as a fraction of the body text.
  #
  # Character position is an approximation of a paginated progression, so a
  # place is chapter-accurate and sentence-near, not page-exact.
  class SpanIndex
    class Unsupported < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason)
      end
    end

    MAX_BYTES = 4.megabytes
    MAX_SPANS = 50_000
    MAX_CFI_BYTES = 1024
    SPAN_ID = /\Akobo\.\d{1,7}\.\d{1,7}\z/
    CFI = %r{\A(?<package>(?:/\d{1,6})+)!(?<path>(?:/\d{1,6})+)(?::(?<offset>\d{1,9}))?\z}
    PARSE = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::RECOVER
    Place = Data.define(:span, :method, :fraction)

    def initialize(data)
      raise Unsupported, "chapter_too_large" if data.bytesize > MAX_BYTES

      @document = Nokogiri::XML(data, nil, nil, PARSE)
      # A document type is common in XHTML, but declarations inside it are
      # never needed for text and are where entity expansion attacks live.
      subset = @document.internal_subset
      raise Unsupported, "unsafe_resource" if subset && !subset.children.empty?

      @root = @document.root
      raise Unsupported, "unreadable_resource" unless @root

      index
      raise Unsupported, "no_kobo_spans" if @spans.empty?
    end

    def locate(locator, spine_index: nil)
      locations = locator.is_a?(Hash) && locator["locations"].is_a?(Hash) ? locator["locations"] : {}
      offset, method = cfi_offset(locations["cfi"], spine_index), "cfi"
      offset, method = fragment_offset(locations["fragments"]), "fragment" if offset.nil?
      if offset.nil?
        progression = locations["progression"]
        progression = 0 unless progression.is_a?(Numeric) && progression.finite? && progression.between?(0, 1)
        offset, method = (progression * @length).floor, "progression"
      end
      span = containing(offset)
      Place.new(span: span.first, method: method, fraction: @length.zero? ? 0.0 : span.last.fdiv(@length).clamp(0.0, 1.0))
    end

    private

    # One pass in document order, without recursion. Offsets are characters of
    # text inside <body> (or the root, for a document without one).
    def index
      body = @root.at_xpath("./*[local-name()='body']") || @root
      @starts = {}
      spans = []
      counts = @document.xpath("//*[@id]").each_with_object(Hash.new(0)) { |node, ids| ids[node["id"]] += 1 }
      position = 0
      stack = [ body ]
      until stack.empty?
        node = stack.pop
        if node.element?
          @starts[node.pointer_id] = position
          id = node["id"]
          if node.name == "span" && id&.match?(SPAN_ID) && node["class"].to_s.split.include?("koboSpan")
            spans << [ id, position ]
            raise Unsupported, "too_many_spans" if spans.size > MAX_SPANS
          end
          node.children.reverse_each { |child| stack << child }
        elsif node.text? || node.cdata?
          @starts[node.pointer_id] = position
          position += node.content.length
        end
      end
      @length = position
      # An id that is not unique does not name one place.
      @spans = spans.select { |id, _| counts[id] == 1 }
    end

    def containing(offset)
      offset = offset.clamp(0, [ @length - 1, 0 ].max)
      index = @spans.bsearch_index { |(_, start)| start > offset }
      @spans[index.nil? ? -1 : [ index - 1, 0 ].max]
    end

    # Only the structural part of a CFI is used: ID assertions are removed,
    # ranges use their start, and the package step must name this chapter.
    def cfi_offset(cfi, spine_index)
      return unless cfi.is_a?(String) && cfi.bytesize <= MAX_CFI_BYTES && !cfi.include?("^")

      inner = cfi.gsub(/\[[^\]\[]*\]/, "")[/\Aepubcfi\((.*)\)\z/m, 1]
      return unless inner

      # A range is "parent,start,end"; its start is the place.
      parent, start, finish, *rest = inner.split(",", -1)
      return unless rest.empty? && (start.nil? || !finish.nil?)

      match = CFI.match("#{parent}#{start}")
      return unless match

      package = match[:package].scan(/\d+/).map(&:to_i)
      return unless package.size == 2 && package.last.even? && (spine_index.nil? || package.last / 2 - 1 == spine_index)

      steps = match[:path].scan(/\d+/).map(&:to_i)
      node = @root
      steps.each_with_index do |step, position|
        return if step.zero?
        return text_offset(node, step, match[:offset].to_i) if step.odd? && position == steps.size - 1
        return if step.odd?

        node = node.element_children[step / 2 - 1]
        return unless node
      end
      @starts[node.pointer_id]
    end

    # The text chunk N (odd steps) lies between element children (N-1)/2 and
    # (N+1)/2; its character offset continues across adjacent text nodes.
    def text_offset(parent, step, characters)
      chunk = (step - 1) / 2
      seen = 0
      parent.children.each do |child|
        if child.element?
          return @starts[child.pointer_id] if seen == chunk

          seen += 1
        elsif seen == chunk && (child.text? || child.cdata?) && @starts.key?(child.pointer_id)
          length = child.content.length
          last = child.next_sibling.nil? || child.next_sibling.element?
          return @starts[child.pointer_id] + [ characters, length ].min if characters < length || last

          characters -= length
        end
      end
      nil
    end

    def fragment_offset(fragments)
      id = fragments.first if fragments.is_a?(Array)
      return unless id.is_a?(String) && id.match?(/\A[^\s"'=]{1,256}\z/)

      matches = @root.xpath(".//*[@id=$id]", nil, id: id)
      @starts[matches.first.pointer_id] if matches.size == 1
    end
  end
end
