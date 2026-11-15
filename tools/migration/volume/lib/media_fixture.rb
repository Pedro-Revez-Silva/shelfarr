# frozen_string_literal: true

require "fileutils"

module Migration
  module Volume
    class MediaFixture
      CONTAINER_ROOTS = { "/audiobooks" => "audiobooks", "/ebooks" => "ebooks", "/references" => "references" }.freeze

      attr_reader :root

      def initialize(root)
        @root = root
      end

      def build
        CONTAINER_ROOTS.each_value { |name| FileUtils.mkdir_p(File.join(@root, name)) }
        write("audiobooks/Ada Author/Synthetic Audio/book.m4b", "synthetic audio stream one", Time.at(1_700_000_000, 123_456_789, :nsec))
        write("audiobooks/Ada Author/Tracked/01.mp3", "synthetic track one", Time.at(1_650_000_000, 5, :nsec))
        write("audiobooks/Ada Author/Tracked/02.mp3", "synthetic track two", Time.at(1_650_000_100, 999_999_999, :nsec))
        write("ebooks/Bea Writer/Quiet Library.epub", "synthetic epub quiet", Time.at(1_600_000_000))
        write("ebooks/Cy Unicode/Café Ébène 日本語.epub", "synthetic epub unicode", Time.at(1_600_000_500, 1, :nsec))
        write("references/ref-target/Imported Elsewhere.epub", "synthetic reference imported epub", Time.at(1_500_000_000, 42, :nsec))
        link = File.join(@root, "ebooks/Dee Linked/Imported Elsewhere.epub")
        FileUtils.mkdir_p(File.dirname(link))
        File.symlink("/references/ref-target/Imported Elsewhere.epub", link)
        self
      end

      def mounts
        CONTAINER_ROOTS.to_h { |container, name| [ container, File.join(@root, name) ] }
      end

      def tree_roots
        CONTAINER_ROOTS.to_h { |container, name| [ container, File.join(@root, name) ] }
      end

      def books
        {
          "audio" => book("Synthetic Audio", "Ada Author", "audiobook", "/audiobooks/Ada Author/Synthetic Audio", request: "completed"),
          "tracks" => book("Tracked", "Ada Author", "audiobook", "/audiobooks/Ada Author/Tracked"),
          "quiet" => book("Quiet Library", "Bea Writer", "ebook", "/ebooks/Bea Writer/Quiet Library.epub", request: "completed"),
          "unicode" => book("Café Ébène 日本語", "Cy Unicode", "ebook", "/ebooks/Cy Unicode/Café Ébène 日本語.epub"),
          "reference" => book("Imported Elsewhere", "Dee Linked", "ebook", "/ebooks/Dee Linked/Imported Elsewhere.epub", reference_target_roots: [ "/references/ref-target" ]),
          "wanted" => { "title" => "Not Yet Acquired", "author" => "Eve Absent", "type" => "ebook", "request" => "pending" }
        }
      end

      private

      def write(relative, content, time)
        path = File.join(@root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
        File.utime(time, time, path)
      end

      def book(title, author, type, path, request: nil, reference_target_roots: nil)
        { "title" => title, "author" => author, "type" => type, "file_path" => path, "request" => request, "reference_target_roots" => reference_target_roots }.compact
      end
    end
  end
end
