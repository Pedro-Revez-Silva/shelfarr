# frozen_string_literal: true

require "test_helper"

class AudiobookshelfLibrarySyncInitializerTest < ActiveJob::TestCase
  INITIALIZER_PATH = Rails.root.join("config/initializers/audiobookshelf_library_sync.rb").to_s
  LIBRARY_SETTING_KEYS = %w[
    library_platform audiobookshelf_url audiobookshelf_api_key
    bookorbit_url bookorbit_username bookorbit_password
    grimmory_url grimmory_username grimmory_password
  ].freeze

  setup do
    Setting.where(key: LIBRARY_SETTING_KEYS).delete_all
    @callback = capture_after_initialize_callback
  end

  test "keeps starting sync for configured Audiobookshelf in server mode" do
    SettingsService.set(:library_platform, "audiobookshelf")
    SettingsService.set(:audiobookshelf_url, "http://audiobookshelf.test")
    SettingsService.set(:audiobookshelf_api_key, "api-key")

    with_rails_server do
      assert_enqueued_with(job: AudiobookshelfLibrarySyncJob) { @callback.call }
    end
  end

  test "starts sync for configured BookOrbit in server mode" do
    configure_bookorbit

    with_rails_server do
      assert_enqueued_with(job: AudiobookshelfLibrarySyncJob) { @callback.call }
    end
  end

  test "starts sync for configured Grimmory in server mode" do
    configure_grimmory

    with_rails_server do
      assert_enqueued_with(job: AudiobookshelfLibrarySyncJob) { @callback.call }
    end
  end

  test "does not start sync when the active library platform is not configured" do
    SettingsService.set(:library_platform, "bookorbit")

    with_rails_server do
      assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) { @callback.call }
    end
  end

  test "does not start sync outside server mode" do
    configure_bookorbit

    without_rails_server do
      assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) { @callback.call }
    end
  end

  private

  def capture_after_initialize_callback
    callback = nil
    capture = ->(&block) { callback = block }

    Rails.application.config.stub(:after_initialize, capture) do
      load INITIALIZER_PATH
    end

    callback || raise("Initializer did not register an after_initialize callback")
  end

  def with_rails_server
    server_defined = Rails.const_defined?(:Server, false)
    Rails.const_set(:Server, Class.new) unless server_defined
    yield
  ensure
    Rails.send(:remove_const, :Server) unless server_defined
  end

  def without_rails_server
    server = Rails.const_get(:Server, false) if Rails.const_defined?(:Server, false)
    Rails.send(:remove_const, :Server) if server
    yield
  ensure
    Rails.const_set(:Server, server) if server
  end

  def configure_bookorbit
    SettingsService.set(:library_platform, "bookorbit")
    SettingsService.set(:bookorbit_url, "http://bookorbit.test")
    SettingsService.set(:bookorbit_username, "admin")
    SettingsService.set(:bookorbit_password, "secret")
  end

  def configure_grimmory
    SettingsService.set(:library_platform, "grimmory")
    SettingsService.set(:grimmory_url, "http://grimmory.test")
    SettingsService.set(:grimmory_username, "admin")
    SettingsService.set(:grimmory_password, "secret")
  end
end
