# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"

class Consumer::ProgressConcurrencyTest < ActiveSupport::TestCase
  include ConsumerTestHelper
  self.use_transactional_tests = false

  setup { prepare_consumer_library }
  teardown do
    @ebook.destroy!
    @audiobook.destroy!
    @token.destroy!
    FileUtils.remove_entry(@root)
  end

  test "two real SQLite connections cannot both replace the same progress version" do
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    asset_id = consumer_asset(@audiobook).id
    threads = [ 10, 20 ].map do |seconds|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          actor = User.find(users(:one).id)
          book = Book.find(@audiobook.id)
          ready << true
          start.pop
          values = audio_progress(asset_id: asset_id, seconds: seconds).stringify_keys
          result = Consumer::ProgressWriter.new(user: actor, book: book).call(values)
          outcomes << [ :saved, result.version ]
        rescue Consumer::ProgressWriter::Conflict => error
          outcomes << [ :conflict, error.progress.version ]
        end
      end
    end
    Timeout.timeout(10) do
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:value)
    end
    assert_equal [ [ :conflict, 1 ], [ :saved, 1 ] ], 2.times.map { outcomes.pop }.sort
    assert_equal 1, users(:one).consumer_progresses.where(book: @audiobook).count
    assert_includes [ 10, 20 ], users(:one).consumer_progresses.find_by!(book: @audiobook).position_seconds
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end
