# frozen_string_literal: true

require "test_helper"

class DirectDownloadRecoveryJobTest < ActiveJob::TestCase
  test "reconciles tracked state and detached reservations then sweeps each output root" do
    request = requests(:pending_request)
    first = request.downloads.create!(
      name: "Tracked direct download",
      status: :failed,
      download_type: "direct",
      direct_staging_path: "/tmp/tracked-direct"
    )
    detached = request.downloads.create!(
      name: "Detached direct reservation",
      status: :failed,
      download_type: "direct",
      direct_reservation_token: SecureRandom.hex(32)
    )
    roots = [ "/ebooks-one", "/audiobooks-two" ]
    reconciled = []
    swept = []
    orphan_sweeps = 0

    DirectDownloadFileService.stub(:reconcile!, ->(download) { reconciled << download.id }) do
      DirectDownloadFileService.stub(:reconcile_orphaned_reservations!, lambda {
        orphan_sweeps += 1
        0
      }) do
        DirectDownloadFileService.stub(:output_roots, roots) do
          DirectDownloadFileService.stub(:cleanup_orphans!, ->(root:) { swept << root; 0 }) do
            DirectDownloadRecoveryJob.perform_now
          end
        end
      end
    end

    assert_equal [ first.id, detached.id ].sort, reconciled.sort
    assert_equal 1, orphan_sweeps
    assert_equal roots, swept
  end
end
