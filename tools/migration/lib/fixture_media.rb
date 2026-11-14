# frozen_string_literal: true

require "fileutils"
require "zip"

module Migration
  class FixtureMedia
    Entry = Data.define(:key, :path)

    FRACTIONAL_MTIME = Time.at(1_700_000_000, 123_456_789, :nsec)
    PRE_EPOCH_MTIME = Time.at(-1, 500_000_000, :nsec)
    WHOLE_SECOND_MTIME = Time.at(1_600_000_000)

    def initialize(paths)
      @paths = paths
      @root = paths.media
      @entries = {}
      @stored_paths = {}
    end

    attr_reader :entries

    def build
      write_plain_epub("quiet", File.join(@root, "The Quiet Library.epub"), FRACTIONAL_MTIME)
      write_plain_file("audio", File.join(@root, "An Audio Book.mp3"), "synthetic audio stream", PRE_EPOCH_MTIME)
      build_multi_track
      write_plain_epub("unicode", File.join(@root, "Café Ébène 日本語.epub"), WHOLE_SECOND_MTIME)
      build_indirect_path
      build_outside_root
      write_plain_file("comic", File.join(@root, "A Comic.cbz"), "not inspected by default readers", WHOLE_SECOND_MTIME)
      write_plain_file("uppercase", File.join(@root, "Loud Book.EPUB"), "synthetic uppercase extension", FRACTIONAL_MTIME)
      self
    end

    def path(key)
      @entries.fetch(key).path
    end

    def stored_path(key)
      @stored_paths.fetch(key, path(key))
    end

    private

    def register(key, path)
      @entries[key] = Entry.new(key: key, path: path)
    end

    def stamp(path, time)
      File.utime(time, time, path)
    end

    def write_plain_file(key, path, content, time)
      File.binwrite(path, content)
      stamp(path, time)
      register(key, path)
    end

    def write_plain_epub(key, path, time)
      files = {
        "mimetype" => "application/epub+zip",
        "META-INF/container.xml" => '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        "OEBPS/content.opf" => %(<package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:#{key}</dc:identifier><dc:title>#{key}</dc:title></metadata><manifest><item id="one" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>),
        "OEBPS/chapter.xhtml" => %(<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Synthetic chapter #{key}</p></body></html>)
      }
      Zip::File.open(path, create: true) { |zip| files.each { |name, content| zip.get_output_stream(name) { |out| out.write(content) } } }
      stamp(path, time)
      register(key, path)
    end

    def build_multi_track
      directory = File.join(@root, "A Listening Life")
      FileUtils.mkdir_p(directory)
      tracks = { "Chapter10.mp3" => Time.at(1_700_000_001), "Chapter2.mp3" => Time.at(-86_400, 250_000_000, :nsec), "Chapter1.mp3" => FRACTIONAL_MTIME }
      tracks.each { |name, time| write_plain_file("track-#{name}", File.join(directory, name), "track #{name}", time) }
      File.binwrite(File.join(directory, "cover.jpg"), "not media")
      File.binwrite(File.join(directory, "notes.txt"), "not media")
      File.binwrite(File.join(directory, ".hidden.mp3"), "hidden")
      register("multi-track-directory", directory)
    end

    def build_indirect_path
      real = File.join(@root, "real")
      FileUtils.mkdir_p(real)
      write_plain_epub("indirect", File.join(real, "Plain Book.epub"), WHOLE_SECOND_MTIME)
      File.symlink(real, File.join(@root, "alias"))
      @stored_paths = { "indirect" => "#{@root}//alias/./detour/../Plain Book.epub" }
    end

    def build_outside_root
      outside = File.join(@paths.out, "outside")
      FileUtils.mkdir_p(outside)
      write_plain_epub("outside", File.join(outside, "Elsewhere.epub"), WHOLE_SECOND_MTIME)
    end
  end
end
