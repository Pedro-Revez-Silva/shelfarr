# frozen_string_literal: true

require "test_helper"
require "turbo/broadcastable/test_helper"

class RequestLiveUpdatesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  class DeterministicRefreshDebouncer
    def debounce(&callback)
      @pending = callback
    end

    def flush
      pending, @pending = @pending, nil
      pending&.call
    end
  end
  private_constant :DeterministicRefreshDebouncer

  setup do
    @old_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @request = Request.create!(
      book: Book.create!(
        title: "Live Update Test #{SecureRandom.hex(4)}",
        book_type: :ebook,
        open_library_work_id: "OL_LIVE_#{SecureRandom.hex(6)}"
      ),
      user: users(:one),
      status: :pending
    )
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @old_queue_adapter
  end

  test "request broadcasts a refresh when visible state changes" do
    streams = capture_refresh_broadcasts(@request) do
      @request.update!(status: :searching)
    end

    assert_refresh_broadcasted(streams)
  end

  test "live update assertions do not depend on the asynchronous debounce scheduler" do
    Concurrent::ScheduledTask.stub(:execute, ->(*) { flunk "Turbo's async scheduler should not run in this test" }) do
      streams = capture_refresh_broadcasts(@request) do
        @request.update!(status: :searching)
      end

      assert_refresh_broadcasted(streams)
    end
  end

  test "request does not broadcast a refresh for non-visible changes" do
    assert_no_refresh_broadcasts(@request) do
      @request.touch
    end
  end

  test "download broadcasts a refresh when progress changes" do
    download = Request.suppressing_turbo_broadcasts do
      @request.downloads.create!(name: "Queued Download", status: :queued)
    end
    clear_enqueued_jobs
    clear_performed_jobs

    streams = capture_refresh_broadcasts(@request) do
      download.update!(progress: 42)
    end

    assert_refresh_broadcasted(streams)
  end

  test "download does not broadcast a refresh for hidden bookkeeping changes" do
    download = Request.suppressing_turbo_broadcasts do
      @request.downloads.create!(name: "Queued Download", status: :queued)
    end
    clear_enqueued_jobs
    clear_performed_jobs

    assert_no_refresh_broadcasts(@request) do
      download.update!(not_found_count: 1)
    end
  end

  test "search result broadcasts a refresh when created" do
    streams = capture_refresh_broadcasts(@request) do
      @request.search_results.create!(guid: "live-result", title: "Live Result")
    end

    assert_refresh_broadcasted(streams)
  end

  test "request event broadcasts a refresh when created" do
    streams = capture_refresh_broadcasts(@request) do
      RequestEvent.create!(
        request: @request,
        event_type: "dispatch_failed",
        source: "DownloadJob",
        level: :error,
        message: "Could not connect"
      )
    end

    assert_refresh_broadcasted(streams)
  end

  private

  def capture_refresh_broadcasts(request, &block)
    Turbo.with_request_id(SecureRandom.uuid) do
      clear_enqueued_jobs
      clear_performed_jobs

      with_deterministic_refresh_debouncer do |debouncer|
        perform_enqueued_jobs do
          capture_turbo_stream_broadcasts(request) do
            block.call
            debouncer.flush
          end
        end
      end
    end
  end

  def assert_no_refresh_broadcasts(request, &block)
    Turbo.with_request_id(SecureRandom.uuid) do
      clear_enqueued_jobs
      clear_performed_jobs

      with_deterministic_refresh_debouncer do |debouncer|
        perform_enqueued_jobs do
          assert_no_turbo_stream_broadcasts(request) do
            block.call
            debouncer.flush
          end
        end
      end
    end
  end

  def with_deterministic_refresh_debouncer
    debouncer = DeterministicRefreshDebouncer.new
    Turbo::StreamsChannel.stub(:refresh_debouncer_for, debouncer) do
      yield debouncer
    end
  end

  def assert_refresh_broadcasted(streams)
    actions = streams.map { |stream| stream["action"] }
    assert_includes actions, "refresh"
    assert actions.all? { |action| action == "refresh" }
  end
end
