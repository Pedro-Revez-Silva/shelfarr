# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_test_helper"

class KoboPublicationTest < ActiveSupport::TestCase
  include KoboTestHelper

  setup { prepare_kobo_book }
  teardown { FileUtils.remove_entry(@root) }

  test "single EPUB and already converted KEPUB keep their original bytes" do
    snapshot = KoboPublication.new(@book).snapshot
    assert_equal "3.0", snapshot.fetch("epub_version")
    assert_equal "EPUB", snapshot.fetch("format")
    assert_equal File.size(@path), snapshot.fetch("size")
    kepub = File.join(@root, "book.kepub.epub")
    File.rename(@path, kepub)
    @book.update!(file_path: kepub)
    assert_equal "KEPUB", KoboPublication.new(@book).snapshot.fetch("format")
  end

  test "book folders accept one nested EPUB but never an entire shared output root or ambiguous folder" do
    directory = File.join(@root, "Author", "Title")
    FileUtils.mkdir_p(directory)
    File.rename(@path, File.join(directory, "Book.epub"))
    File.write(File.join(directory, "cover.jpg"), "cover")
    @book.update!(file_path: File.dirname(directory))
    assert_equal "Book.epub", KoboPublication.new(@book).snapshot.fetch("filename")
    write_epub(File.join(directory, "other.epub"))
    assert_raises(KoboPublication::Unavailable) { KoboPublication.new(@book).snapshot }
    @book.update!(file_path: @root)
    assert_raises(KoboPublication::Unavailable) { KoboPublication.new(@book).snapshot }
  end

  test "authorized reference leaves work and symlinks outside recorded roots fail closed" do
    target_root = Dir.mktmpdir("kobo-reference")
    target = File.join(target_root, "Book.epub")
    File.rename(@path, target)
    File.symlink(target, @path)
    stat = File.stat(target_root)
    @book.update!(reference_target_roots: [ Book::ReferenceTargetRoot.new(path: target_root, device: stat.dev, inode: stat.ino) ])
    assert_equal File.size(target), KoboPublication.new(@book).snapshot.fetch("size")
    @book.update!(reference_target_roots: nil)
    assert_raises(KoboPublication::Unavailable) { KoboPublication.new(@book).snapshot }
  ensure
    FileUtils.remove_entry(target_root) if target_root
  end

  test "unsafe roots, wrong media types and invalid EPUBs never become deliveries" do
    @book.update!(book_type: :audiobook)
    assert_raises(KoboPublication::Unavailable) { @device.send_book!(@book) }
    @book.update!(book_type: :ebook, file_path: "/etc/passwd")
    assert_raises(KoboPublication::Unavailable) { @device.send_book!(@book) }
    @book.update!(file_path: @path)
    File.binwrite(@path, "not a zip")
    assert_raises(KoboPublication::Unavailable) { @device.send_book!(@book) }
    assert_empty @device.kobo_deliveries
    assert_equal 0, @device.reload.sync_revision
  end

  test "EPUB metadata cannot read local files or expand entities and is bounded" do
    write_epub(@path, package: '<!DOCTYPE package [<!ENTITY secret SYSTEM "file:///etc/passwd">]><package version="3.0">&secret;</package>')
    assert_raises(KoboPublication::Unavailable) { KoboPublication.new(@book).snapshot }
    write_epub(@path, extra: { "META-INF/container.xml" => "x" * (KoboPublication::MAX_XML_BYTES + 1) })
    assert_raises(KoboPublication::Unavailable) { KoboPublication.new(@book).snapshot }
    write_epub(@path, extra: { "META-INF/encryption.xml" => "encrypted" })
    assert_raises(KoboPublication::Unavailable) { KoboPublication.new(@book).snapshot }
  end

  test "download pin cannot follow a later path replacement" do
    publication = KoboPublication.new(@book)
    snapshot = publication.snapshot
    file = publication.open_file(expected_fingerprint: snapshot.fetch("fingerprint"))
    expected = File.binread(@path)
    File.rename(@path, "#{@path}.old")
    File.write(@path, "unrelated private bytes")
    assert_equal expected, file.read
    assert_raises(KoboPublication::Unavailable) { publication.open_file(expected_fingerprint: snapshot.fetch("fingerprint")) }
  ensure
    file&.close
  end

  test "in-place source modifications invalidate a queued publication" do
    fingerprint = KoboPublication.new(@book).snapshot.fetch("fingerprint")
    File.open(@path, "r+b") { |file| file.write("changed") }
    assert_raises(KoboPublication::Unavailable) { KoboPublication.new(@book).open_file(expected_fingerprint: fingerprint) }
  end
end
