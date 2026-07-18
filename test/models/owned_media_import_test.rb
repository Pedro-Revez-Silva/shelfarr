# frozen_string_literal: true

require "test_helper"

class OwnedMediaImportTest < ActiveJob::TestCase
  setup do
    @connection = OwnedLibraryConnection.create!(enabled: true, last_synced_at: Time.current)
    @item = @connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "A Title",
      ownership_type: "purchased"
    )
    clear_enqueued_jobs
  end

  test "only allows one active import for an item" do
    @item.owned_media_imports.create!(status: "queued")
    duplicate = @item.owned_media_imports.new(status: "downloading")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:base], "A backup is already active for this library item"
  end

  test "pending backlog work is passive until dispatched" do
    media_import = @item.owned_media_imports.create!(status: "pending", automatic: true)

    assert media_import.pending?
    assert_not media_import.active?
    assert_not media_import.terminal?
    assert_includes OwnedMediaImport.pending, media_import
    assert_not_includes OwnedMediaImport.active, media_import
  end

  test "allows a new import after the previous import failed" do
    @item.owned_media_imports.create!(status: "failed")
    replacement = @item.owned_media_imports.new(status: "queued")

    assert replacement.valid?, replacement.errors.full_messages.join(", ")
  end

  test "a failed import with a durable destination reservation blocks a replacement" do
    failed = @item.owned_media_imports.create!(
      status: "failed",
      destination_path: "/library/Author/Title/book.m4b",
      library_path: "/library/Author/Title"
    )
    replacement = @item.owned_media_imports.new(status: "queued")

    assert failed.recovery_reserved?
    assert_includes OwnedMediaImport.recovery_reserved, failed
    assert_not replacement.valid?
    assert_includes replacement.errors[:base], "A backup is already active for this library item"
  end

  test "mark failed records a terminal error" do
    media_import = @item.owned_media_imports.create!(status: "queued")

    media_import.mark_failed!("failure")

    assert media_import.failed?
    assert media_import.terminal?
    assert_equal "failure", media_import.error_message
    assert media_import.completed_at.present?
  end

  test "a stale failure cannot overwrite a newer completed state" do
    media_import = @item.owned_media_imports.create!(status: "processing")
    stale_import = OwnedMediaImport.find(media_import.id)
    completed_at = Time.current
    media_import.update!(status: "completed", completed_at: completed_at)

    assert_equal false, stale_import.mark_failed!("late failure")

    stale_import.reload
    assert stale_import.completed?
    assert_nil stale_import.error_message
    assert_in_delta completed_at, stale_import.completed_at, 1.second
  end

  test "a stale polling chain cannot mark an active import failed" do
    media_import = @item.owned_media_imports.create!(
      status: "processing",
      poll_token: OwnedMediaImport.generate_poll_token
    )
    stale_token = media_import.poll_token
    current_token = OwnedMediaImport.generate_poll_token
    media_import.update!(poll_token: current_token)

    assert_equal false, media_import.mark_failed!("stale failure", poll_token: stale_token)
    assert media_import.reload.processing?
    assert_nil media_import.error_message

    assert_equal true, media_import.mark_failed!("current failure", poll_token: current_token)
    assert media_import.reload.failed?
  end

  test "a legacy timestamp polling job upgrades to a durable token once" do
    media_import = @item.owned_media_imports.create!(status: "queued")
    legacy_token = media_import.updated_at.utc.iso8601(6)

    durable_token = media_import.claim_poll_token(legacy_token)

    assert durable_token.present?
    assert_equal durable_token, media_import.reload.poll_token
    assert_nil media_import.claim_poll_token(legacy_token)
    assert_equal durable_token, media_import.claim_poll_token(durable_token)
  end

  test "an enqueued deterministic successor can self-promote after a worker exit" do
    current_token = OwnedMediaImport.generate_poll_token
    media_import = @item.owned_media_imports.create!(
      status: "queued",
      poll_token: current_token
    )
    successor = OwnedMediaImport.next_poll_token(current_token)

    # schedule_poll enqueues this successor before its parent promotes it. If
    # that parent exits in the handoff window, the delayed job performs this
    # same atomic promotion when it starts.
    assert_equal successor, media_import.claim_poll_token(successor)
    assert_equal successor, media_import.reload.poll_token
    assert_nil media_import.claim_poll_token(current_token)
  end

  test "a completed dispatched automatic import immediately admits its successor" do
    media_import, successor = dispatched_import_with_pending_successor

    assert_enqueued_with(
      job: OwnedMediaBackupJob,
      args: ->(args) { args.first == successor.id && args.second.present? }
    ) do
      media_import.update!(status: "completed", completed_at: Time.current)
    end

    successor.reload
    assert successor.queued?
    assert successor.dispatched_at.present?
    assert successor.poll_token.present?
  end

  test "a failed dispatched automatic import immediately admits its successor" do
    media_import, successor = dispatched_import_with_pending_successor

    assert_enqueued_with(
      job: OwnedMediaBackupJob,
      args: ->(args) { args.first == successor.id && args.second.present? }
    ) do
      assert media_import.mark_failed!("Libation failed")
    end

    assert successor.reload.queued?
  end

  test "later edits to a terminal automatic import do not amplify dispatch" do
    media_import = @item.owned_media_imports.create!(
      status: "processing",
      automatic: true,
      dispatched_at: Time.current,
      requested_by: users(:two)
    )
    dispatch_calls = 0
    dispatcher = lambda do |connection:|
      assert_equal @connection, connection
      dispatch_calls += 1
    end

    OwnedLibraryBacklogBackup.stub(:dispatch_next, dispatcher) do
      media_import.update!(status: "completed", completed_at: Time.current)
      media_import.update!(error_message: "post-completion annotation")
    end

    assert_equal 1, dispatch_calls
  end

  test "cannot destroy queued or recovery-owning imports" do
    pending = @item.owned_media_imports.create!(status: "pending", automatic: true)

    assert_not pending.destroy
    assert pending.persisted?
    assert_match(/cannot be deleted safely/, pending.errors.full_messages.to_sentence)

    pending.update!(
      status: "failed",
      destination_path: "/library/Author/Title/book.m4b",
      library_path: "/library/Author/Title"
    )
    assert_not pending.destroy
    assert pending.persisted?

    pending.update!(status: "completed")
    assert pending.destroy
  end

  private

  def dispatched_import_with_pending_successor
    media_import = @item.owned_media_imports.create!(
      status: "processing",
      automatic: true,
      dispatched_at: Time.current,
      requested_by: users(:two)
    )
    successor_item = @connection.owned_library_items.create!(
      external_id: "B087654321",
      title: "Automatic successor",
      ownership_type: "purchased"
    )
    successor = successor_item.owned_media_imports.create!(
      status: "pending",
      automatic: true,
      requested_by: users(:two)
    )
    clear_enqueued_jobs

    [ media_import, successor ]
  end
end
