# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"

class Consumer::LibraryAssetsTest < ActiveSupport::TestCase
  include ConsumerTestHelper
  setup { prepare_consumer_library }
  teardown { FileUtils.remove_entry(@root) }

  test "multi-track audio is naturally ordered without sidecars or foreign media" do
    directory = File.join(@root, "A Listening Life")
    FileUtils.mkdir_p(directory)
    %w[Chapter10.mp3 Chapter2.mp3 Chapter1.mp3 cover.jpg notes.txt unrelated.epub].each do |filename|
      File.write(File.join(directory, filename), "content")
    end
    @audiobook.update!(file_path: directory)
    assets = Consumer::LibraryAssets.new(@audiobook).list
    assert_equal %w[Chapter1.mp3 Chapter2.mp3 Chapter10.mp3], assets.map(&:filename)
    assert_equal [ 0, 1, 2 ], assets.map(&:position)
    assert_equal 3, assets.map(&:id).uniq.size
    assert_equal assets.map(&:id), Consumer::LibraryAssets.new(@audiobook).list.map(&:id)
  end

  test "reference imports retain authorized targets and reject unrecorded outside roots" do
    target_root = Dir.mktmpdir("consumer-reference")
    target = File.join(target_root, "Library.epub")
    File.rename(@epub_path, target)
    File.symlink(target, @epub_path)
    stat = File.stat(target_root)
    @ebook.update!(reference_target_roots: [ Book::ReferenceTargetRoot.new(path: target_root, device: stat.dev, inode: stat.ino) ])
    source = Consumer::LibraryAssets.new(@ebook)
    asset = source.list.sole
    _, file = source.open(asset.id)
    assert_equal File.binread(target), file.read
    file.close
    @ebook.update!(reference_target_roots: nil)
    assert_raises(Consumer::LibraryAssets::Unavailable) { source.open(asset.id) }
  ensure
    file&.close unless file&.closed?
    FileUtils.remove_entry(target_root) if target_root
  end

  test "an opened asset remains pinned when its pathname is replaced" do
    source = Consumer::LibraryAssets.new(@audiobook)
    asset = source.list.sole
    _, file = source.open(asset.id)
    expected = File.binread(@audio_path)
    File.rename(@audio_path, "#{@audio_path}.old")
    File.write(@audio_path, "different bytes")
    assert_equal expected, file.read
    assert_raises(Consumer::LibraryAssets::Unavailable) { source.open(asset.id) }
    assert_not_equal asset.id, source.list.sole.id
  ensure
    file&.close
  end
end
