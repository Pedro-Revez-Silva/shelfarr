# frozen_string_literal: true

require "test_helper"

class AudiobookshelfLibrarySyncJobTest < ActiveJob::TestCase
  setup do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-audio")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_library_sync_interval, 3600)
  end

  test "schedules next run after syncing" do
    LibraryItem.destroy_all

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/lib-audio/items")
        .with(
          headers: { "Authorization" => "Bearer test-api-key" },
          query: hash_including("limit" => "500", "page" => "0")
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-1",
                "title" => "The Hobbit",
                "author" => "J.R.R. Tolkien"
              }
            ],
            "total" => 1
          }.to_json
        )

      assert_enqueued_with(job: AudiobookshelfLibrarySyncJob) do
        AudiobookshelfLibrarySyncJob.perform_now
      end
    end

    assert_equal 1, LibraryItem.count
    assert_equal "The Hobbit", LibraryItem.first.title
  end

  test "does not reschedule when interval is zero" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobookshelf_api_key, "")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_library_sync_interval, 0)

    clear_enqueued_jobs

    with_sync_interval_stub(0) do
      assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) do
        assert_nothing_raised do
          AudiobookshelfLibrarySyncJob.perform_now
        end
      end
    end
  end

  private

  def with_sync_interval_stub(interval)
    singleton = class << SettingsService; self; end
    original_get = singleton.instance_method(:get)
    singleton.define_method(:get) do |key, default: nil|
      key.to_sym == :audiobookshelf_library_sync_interval ? interval : original_get.bind_call(self, key, default: default)
    end
    yield
  ensure
    singleton.define_method(:get, original_get)
  end
end
