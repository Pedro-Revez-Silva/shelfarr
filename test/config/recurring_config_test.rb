# frozen_string_literal: true

require "test_helper"

class RecurringConfigTest < ActiveSupport::TestCase
  test "schedules book metadata backfill daily" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    default_jobs = config.fetch("default")
    backfill_job = default_jobs.fetch("book_metadata_backfill")

    assert_equal "BookMetadataBackfillJob", backfill_job["class"]
    assert_equal "default", backfill_job["queue"]
    assert_equal "at 3am every day", backfill_job["schedule"]
  end
end
