# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/kobo_test_helper"

class Kobo::KepubCacheRebuildTest < ActiveSupport::TestCase
  include KoboTestHelper

  setup do
    prepare_kobo_book
    prepare_plain_epub
  end
  teardown { FileUtils.remove_entry(@root) }

  def bytes(delivery)
    file = delivery.reload.open_file
    file.read
  ensure
    file&.close
  end

  test "different valid source containers producing the same edition can both rebuild their delivered copy" do
    first = @device.send_book!(@book)
    expected = bytes(first)
    path = File.join(@root, "Same text other container.epub")
    File.binwrite(path, File.binread(@path))
    Zip::File.open(path) { |zip| zip.comment = "A distinct source container with identical content" }
    other = Book.create!(title: "Same text other container", author: "Author", book_type: :ebook, file_path: path)
    second = @device.send_book!(other)
    assert_not_equal Digest::SHA256.file(@path).hexdigest, Digest::SHA256.file(path).hexdigest
    assert_equal first.kobo_kepub_copy.sha256, second.kobo_kepub_copy.sha256, "the converted files have the same bytes"
    File.unlink(Kobo::KepubCache.root.join(first.kobo_kepub_copy.storage_key))
    assert_equal expected, bytes(first), "the first unchanged source must still rebuild after another source produced the same bytes"
    assert_equal expected, bytes(second)
  end

  test "a valid highly compressed chapter can rebuild its small delivered copy" do
    chapter = %(<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Large text</title></head><body><p>#{'Quiet words without punctuation ' * 40_000}</p></body></html>)
    prepare_plain_epub(chapters: { "OEBPS/Text/ch2.xhtml" => chapter })
    delivery = @device.send_book!(@book)
    assert_equal "KEPUB", delivery.publication["format"]
    expected = bytes(delivery)
    assert_operator chapter.bytesize, :>, 1.megabyte
    assert_operator expected.bytesize, :<, 100.kilobytes
    File.unlink(Kobo::KepubCache.root.join(delivery.kobo_kepub_copy.storage_key))
    assert_equal expected, bytes(delivery), "the output bound must count compressed output, not reject the expanded chapter"
  end

  test "rebuilding a corrupt copy never writes beyond the cache capacity" do
    delivery = @device.send_book!(@book)
    expected = bytes(delivery)
    copy = delivery.kobo_kepub_copy
    path = Kobo::KepubCache.root.join(copy.storage_key)
    File.open(path, "r+b") { |file| file.seek(70); file.write("X") }
    observed = []
    cache_root = Kobo::KepubCache.root
    factory = Kobo::KepubConverter.method(:new)
    replacement = lambda do |source|
      converter = factory.call(source)
      write = converter.method(:write)
      converter.define_singleton_method(:write) do |io, limit:|
        result = write.call(io, limit: limit)
        io.flush
        observed << Dir.glob("**/*", File::FNM_DOTMATCH, base: cache_root).sum { |name| (file = cache_root.join(name)).file? ? file.size : 0 }
        result
      end
      converter
    end
    with_env("KOBO_KEPUB_CACHE_MAX_BYTES" => copy.size_bytes.to_s) do
      Kobo::KepubConverter.stub(:new, replacement) { assert_equal expected, bytes(delivery) }
    end
    assert_not_empty observed
    assert_operator observed.max, :<=, copy.size_bytes, "partial output and existing files must fit even before promotion"
  end

  test "a failed conversion never writes even a partial output past its limit" do
    target = File.join(@root, "bounded-output.part")
    File.open(@path, "rb") do |source|
      File.open(target, "wb") do |output|
        assert_raises(Kobo::KepubConverter::LimitExceeded) { Kobo::KepubConverter.new(source).write(output, limit: 300) }
      end
    end
    assert_operator File.size(target), :<=, 300
  end
end
