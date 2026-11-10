# frozen_string_literal: true

require "zip"

module Kobo
  # Writes a Kobo edition (KEPUB) of one DRM-free library EPUB.
  #
  # Kobo opens a plain .epub with its Adobe engine and a .kepub.epub with its
  # own engine (kobolabs/epub-spec). Only the Kobo engine names a reading place
  # by chapter resource and a <span class="koboSpan" id="kobo.P.S"> sentence
  # marker that exists in the file. This writes those markers into a separate
  # delivery copy; the library file is only read.
  #
  # The markup follows kepubify (pgaskin/kepubify, kepub/kobo.go at 79f99c9):
  # every sentence of body text gets a span, a paragraph counter advances at
  # p, ol, ul, table, h1-h6 and img (which is wrapped in its own span), and the
  # body content is wrapped in div#book-columns > div#book-inner with Kobo's
  # style tweak in the head. Unlike kepubify, nothing else changes: no text is
  # removed or rewritten, so each chapter's body text is character-for-character
  # the original's. A place found in the original chapter is therefore the same
  # character offset in the copy (see SpanIndex#locate with original:).
  #
  # Only spine XHTML documents are rewritten. Every other entry (navigation,
  # NCX, package, styles, images, fonts) is copied with its original compressed
  # bytes, so paths, EPUB 2/3 navigation and assets stay exactly as they were.
  # The output is deterministic for the same source bytes.
  #
  # Anything that cannot be converted safely raises Unsupported with a reason:
  # the delivery then stays a plain EPUB, exactly as before.
  class KepubConverter
    VERSION = "shelfarr-kepub-1"
    XHTML = "http://www.w3.org/1999/xhtml"
    XHTML_TYPE = "application/xhtml+xml"
    MIMETYPE = "application/epub+zip"
    MAX_CHAPTER_BYTES = SpanIndex::MAX_BYTES
    MAX_INFLATED_BYTES = 512.megabytes
    MAX_NAME_BYTES = 1024
    # Strict XML without network, DTD loading or entity substitution: the tree
    # written back is exactly the one read, and entities stay references.
    PARSE = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::STRICT
    # kepubify's sentence rule: punctuation, an optional closing quote or
    # ellipsis, then ASCII whitespace ends a sentence.
    SENTENCE = /.*?[.!?]['"“”’…]?[\t\n\f\r ]+/m
    PARAGRAPHS = %w[p ol ul table h1 h2 h3 h4 h5 h6].to_set.freeze
    QUIET = %w[script style pre audio video svg math].to_set.freeze
    QUIET_HTML = %w[textarea title].to_set.freeze
    VOID = %w[area base br col embed hr img input link meta param source track wbr].to_set.freeze
    STYLE = "div#book-inner { margin-top: 0; margin-bottom: 0;}"
    WRAPPER_IDS = %w[book-columns book-inner].freeze
    KOBO_ID = /\Akobo\.\d+\.\d+\z/
    PROTECTED = %w[META-INF/encryption.xml META-INF/rights.xml].freeze
    Result = Data.define(:chapters, :spans)

    class Unsupported < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason)
      end
    end

    # The copy would exceed the output limit the caller allowed.
    class LimitExceeded < StandardError; end

    # Bound actual ZIP bytes, including raw entries and the central directory.
    # Expanded chapter XML can be much larger than its compressed output.
    class LimitedOutput
      extend Forwardable
      def_delegators :@io, :binmode, :rewind, :seek, :tell, :pos, :pos=, :flush, :close
      attr_reader :io, :copies

      def initialize(io, limit)
        @io, @limit = io, limit
        @copies = []
      end

      def initialize_copy(other)
        super
        @io = other.io.dup
        @copies = other.copies
        @copies << @io
      end

      def reopen(other)
        @io.reopen(other.io)
        self
      end

      def write(data)
        raise LimitExceeded if @io.pos + data.bytesize > @limit

        @io.write(data)
      end

      def close_duplicates
        copies.each { |file| file.close unless file.closed? }
      end

      def <<(data)
        write(data)
        self
      end
    end

    class << self
      # Proof that a written copy is the conversion of this source: the same
      # entries, a valid unencrypted EPUB, and for every rewritten chapter the
      # same body text as the original with unique, real Kobo spans. Returns
      # the number of spans.
      def verify(source, copy, chapters:)
        KoboPublication.validate_file(copy)
        source_names = archive(source) { |zip| zip.entries.reject(&:directory?).map(&:name) - [ "mimetype" ] }
        copy_names = archive(copy) { |zip| zip.entries.map(&:name) }
        raise Unsupported, "verification_failed" unless copy_names == [ "mimetype", *source_names ]

        publication = KoboPublication.new(nil)
        chapters.sum do |path|
          original = SpanIndex.new(publication.resource(source, path, limit: MAX_CHAPTER_BYTES), require_spans: false)
          converted = SpanIndex.new(publication.resource(copy, path, limit: MAX_CHAPTER_BYTES), require_spans: false)
          raise Unsupported, "verification_failed" unless original.text == converted.text && original.span_ids.empty?

          converted.span_ids.size
        end
      rescue SpanIndex::Unsupported, KoboPublication::Unavailable
        raise Unsupported, "verification_failed"
      end

      def archive(file)
        count = Zip::File.count_entries(file)
        raise Unsupported, "too_many_entries" if count > KoboPublication::MAX_ENTRIES

        zip = Zip::File.open_buffer(KoboPublication::ArchiveIO.new(file))
        raise Unsupported, "duplicate_entries" unless zip.size == count

        yield zip
      rescue Zip::Error
        raise Unsupported, "unreadable_archive"
      ensure
        zip&.close
      end
    end

    # source: a pinned, already validated library EPUB descriptor.
    def initialize(source)
      @source = source
    end

    # Writes the copy to io (an empty, seekable file) without exceeding limit
    # bytes. Returns the rewritten chapters (decoded ZIP paths) and span count.
    def write(io, limit:)
      bounded = nil
      order = KoboPublication.new(nil).reading_order(@source).fetch("items")
      self.class.archive(@source) do |zip|
        check_entries(zip)
        chapters = order.filter_map { |path, item| path if item["type"] == XHTML_TYPE && zip.find_entry(path) }.uniq
        raise Unsupported, "no_text" if chapters.empty?

        spans = 0
        targets = chapters.to_set
        bounded = LimitedOutput.new(io, limit)
        Zip::OutputStream.write_buffer(bounded) do |out|
          # Known sizes keep every local header free of a ZIP64 placeholder;
          # the mimetype entry stays first, stored and without extra fields.
          out.put_next_entry(Zip::Entry.new("", "mimetype", compression_method: Zip::Entry::STORED, size: MIMETYPE.bytesize,
            time: Zip::DOSTime.new(1980, 1, 1)))
          out << MIMETYPE
          zip.entries.each do |entry|
            next if entry.directory? || entry.name == "mimetype"

            if targets.include?(entry.name)
              data, count = convert(read(entry))
              out.put_next_entry(Zip::Entry.new("", entry.name, compression_method: Zip::Entry::DEFLATED, size: data.bytesize, time: entry.time))
              out << data
              spans += count
            else
              raw = entry.dup
              # Sizes are written into the copied local header, so a source
              # data descriptor (bit 3) would no longer follow the data.
              raw.gp_flags &= ~0x08
              out.copy_raw_entry(raw)
            end
          end
        end
        Result.new(chapters: chapters, spans: spans)
      end
    rescue Zip::Error, IOError
      raise Unsupported, "unreadable_archive"
    rescue KoboPublication::Unavailable
      raise Unsupported, "unreadable_archive"
    ensure
      bounded&.close_duplicates
    end

    private

    # No entry may be encrypted, a symlink, a duplicate (checked when opened),
    # outside the archive root, or part of an inflation beyond the bound.
    def check_entries(zip)
      inflated = 0
      zip.entries.each do |entry|
        name = entry.name
        raise Unsupported, "protected" if PROTECTED.include?(name) || entry.encrypted?
        raise Unsupported, "unsafe_entry" if entry.symlink? || unsafe_name?(name)

        inflated += entry.size.to_i
        raise Unsupported, "too_large" if inflated > MAX_INFLATED_BYTES || entry.compressed_size > @source.stat.size
      end
    end

    def unsafe_name?(name)
      !name.valid_encoding? || name.bytesize > MAX_NAME_BYTES || name.match?(/[\x00-\x1f\\]/) || name.start_with?("/") ||
        name.split("/").include?("..")
    end

    def read(entry)
      raise Unsupported, "chapter_too_large" if entry.size > MAX_CHAPTER_BYTES
      raise Unsupported, "unsupported_compression" unless [ Zip::Entry::STORED, Zip::Entry::DEFLATED ].include?(entry.compression_method)

      data = entry.get_input_stream { |input| input.read(MAX_CHAPTER_BYTES + 1) }.to_s
      raise Unsupported, "chapter_too_large" if data.bytesize > MAX_CHAPTER_BYTES
      raise Unsupported, "unreadable_archive" unless data.bytesize == entry.size

      data
    end

    # One chapter's markup with Kobo spans. Returns [bytes, span count].
    def convert(data)
      document = Nokogiri::XML(data, nil, nil, PARSE)
      subset = document.internal_subset
      raise Unsupported, "unsafe_resource" if subset && !subset.children.empty?

      root = document.root
      body = root&.at_xpath("./*[local-name()='body']")
      raise Unsupported, "not_xhtml" unless body && html?(root)

      ids = document.xpath("//@id").map(&:value)
      if ids.any? { |id| id.match?(KOBO_ID) } || document.xpath("//*[local-name()='span'][contains(concat(' ', normalize-space(@class), ' '), ' koboSpan ')]").any?
        raise Unsupported, "already_kobo_markup"
      end

      @document = document
      @namespace = root.namespace if root.namespace&.href == XHTML
      count = add_spans(body)
      wrap(body) if (ids & WRAPPER_IDS).empty?
      add_style(root.at_xpath("./*[local-name()='head']"))
      close_empty_elements
      output = document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML, encoding: "UTF-8")
      raise Unsupported, "chapter_too_large" if output.bytesize > MAX_CHAPTER_BYTES

      [ output.b, count ]
    rescue Nokogiri::XML::SyntaxError, EncodingError
      raise Unsupported, "not_well_formed"
    end

    # Document order, without recursion, recorded before any change.
    def add_spans(body)
      events = []
      stack = body.children.reverse.map { |child| [ child, false, false ] }
      until stack.empty?
        node, quiet, in_p = stack.pop
        if node.element?
          html = html?(node)
          inner_quiet = quiet || QUIET.include?(node.name) || (html && QUIET_HTML.include?(node.name))
          events << [ :element, node, quiet, html ]
          node.children.reverse_each { |child| stack << [ child, inner_quiet, html && node.name == "p" ] }
        elsif node.text?
          events << [ :text, node, quiet, in_p ]
        end
      end

      @paragraph = 0
      @sentence = 0
      @new_paragraph = false
      @count = 0
      events.each do |kind, node, quiet, flag|
        next if quiet

        kind == :element ? element(node, flag) : text(node, flag)
      end
      @count
    end

    def element(node, html)
      return unless html

      if node.name == "img"
        @new_paragraph = true
        span = span_element
        node.add_previous_sibling(span)
        span.add_child(node)
      elsif PARAGRAPHS.include?(node.name)
        @new_paragraph = true
      end
    end

    # A sentence gets a span unless it is only whitespace outside a p. The
    # text node is replaced through a placeholder, so libxml cannot merge new
    # text into the node being removed.
    def text(node, in_p)
      content = node.content
      pieces = content.scan(SENTENCE)
      rest = content[pieces.sum(&:length)..]
      pieces << rest unless rest.empty?
      raise Unsupported, "verification_failed" unless pieces.join == content

      placeholder = new_element("span")
      node.replace(placeholder)
      pieces.each do |piece|
        if in_p || !piece.match?(/\A[[:space:]]*\z/)
          span = span_element
          span.add_child(Nokogiri::XML::Text.new(piece, @document))
          placeholder.add_previous_sibling(span)
        else
          placeholder.add_previous_sibling(Nokogiri::XML::Text.new(piece, @document))
        end
      end
      placeholder.remove
    end

    def span_element
      if @new_paragraph
        @new_paragraph = false
        @paragraph += 1
        @sentence = 0
      end
      @sentence += 1
      @count += 1
      raise Unsupported, "too_many_spans" if @count > SpanIndex::MAX_SPANS

      new_element("span", "class" => "koboSpan", "id" => "kobo.#{@paragraph}.#{@sentence}")
    end

    def wrap(body)
      columns = new_element("div", "id" => "book-columns")
      inner = new_element("div", "id" => "book-inner")
      body.children.each { |child| inner.add_child(child) }
      columns.add_child(inner)
      body.add_child(columns)
    end

    def add_style(head)
      return unless head

      style = new_element("style", "type" => "text/css", "class" => "kobostylehacks")
      style.add_child(Nokogiri::XML::Text.new(STYLE, @document))
      head.add_child(style)
    end

    # An empty non-void element is written with an end tag, as kepubify's
    # polyglot output does, so an HTML parser reads the same tree.
    def close_empty_elements
      @document.xpath("//*[not(node())]").each do |node|
        node.add_child(Nokogiri::XML::Text.new("", @document)) if html?(node) && !VOID.include?(node.name)
      end
    end

    def new_element(name, attributes = {})
      node = Nokogiri::XML::Node.new(name, @document)
      node.namespace = @namespace if @namespace
      attributes.each { |key, value| node[key] = value }
      node
    end

    def html?(node)
      node.namespace.nil? || node.namespace.href == XHTML
    end
  end
end
