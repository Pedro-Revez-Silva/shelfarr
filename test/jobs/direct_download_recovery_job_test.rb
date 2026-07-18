# frozen_string_literal: true

require "test_helper"

class DirectDownloadRecoveryJobTest < ActiveJob::TestCase
  test "reconciles every tracked direct download and sweeps each output root" do
    request = requests(:pending_request)
    first = request.downloads.create!(
      name: "Tracked direct download",
      status: :failed,
      download_type: "direct",
      direct_staging_path: "/tmp/tracked-direct"
    )
    roots = [ "/ebooks-one", "/audiobooks-two" ]
    reconciled = []
    swept = []

    DirectDownloadFileService.stub(:reconcile!, ->(download) { reconciled << download.id }) do
      DirectDownloadFileService.stub(:output_roots, roots) do
        DirectDownloadFileService.stub(:cleanup_orphans!, ->(root:) { swept << root; 0 }) do
          DirectDownloadRecoveryJob.perform_now
        end
      end
    end

    assert_equal [ first.id ], reconciled
    assert_equal roots, swept
  end
end
