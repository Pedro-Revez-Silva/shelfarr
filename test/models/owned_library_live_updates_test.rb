# frozen_string_literal: true

require "test_helper"
require "turbo/broadcastable/test_helper"

class OwnedLibraryLiveUpdatesTest < ActiveSupport::TestCase
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
    @connection = OwnedLibraryConnection.create!
    @item = @connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Live Audible Title",
      ownership_type: "purchased"
    )
  end

  test "sync state changes broadcast a page refresh" do
    streams = capture_refreshes do
      @connection.update!(sync_status: "queued", sync_started_at: Time.current)
    end

    assert_refresh_broadcasted(streams)
  end

  test "backup lifecycle changes broadcast a page refresh" do
    media_import = @item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "queued"
    )
    clear_enqueued_jobs
    clear_performed_jobs

    streams = capture_refreshes do
      media_import.update!(status: "downloading", started_at: Time.current)
    end

    assert_refresh_broadcasted(streams)
  end

  test "unrelated connection touches do not broadcast" do
    streams = capture_refreshes { @connection.touch }

    assert_empty streams
  end

  private

  def capture_refreshes(&block)
    Turbo.with_request_id(SecureRandom.uuid) do
      clear_enqueued_jobs
      clear_performed_jobs
      debouncer = DeterministicRefreshDebouncer.new

      Turbo::StreamsChannel.stub(:refresh_debouncer_for, debouncer) do
        perform_enqueued_jobs do
          capture_turbo_stream_broadcasts(@connection) do
            block.call
            debouncer.flush
          end
        end
      end
    end
  end

  def assert_refresh_broadcasted(streams)
    actions = streams.map { |stream| stream["action"] }
    assert_includes actions, "refresh"
    assert actions.all? { |action| action == "refresh" }
  end
end
