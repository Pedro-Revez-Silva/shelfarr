# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class OwnedLibraryBackupFlowTest < ActionDispatch::IntegrationTest
  test "completed Audible backup becomes the canonical acquired library book" do
    admin = users(:two)
    sign_in_as(admin)

    connection = OwnedLibraryConnection.create!(
      url: "https://libation.test",
      allow_private_network: false,
      bridge_token: "token",
      enabled: true
    )
    item = connection.owned_library_items.create!(
      external_id: "B012345678",
      title: "Canonical Audible Integration",
      authors: [ "Queue Test Author" ],
      ownership_type: "purchased"
    )
    media_import = nil

    Dir.mktmpdir("owned-library-backup-flow") do |root|
      import_root = File.join(root, "imports")
      output_root = File.join(root, "library")
      source_directory = File.join(import_root, "Queue Test Author")
      source_path = File.join(
        source_directory,
        "Queue Test Author - Canonical Audible Integration.m4b"
      )
      FileUtils.mkdir_p(source_directory)
      File.binwrite(source_path, "test audio")
      SettingsService.set(:audiobook_output_path, output_root)

      clear_enqueued_jobs
      assert_difference -> { OwnedMediaImport.count }, 1 do
        post backup_item_admin_owned_library_connection_url(connection, item_id: item.id),
          headers: { "HTTP_REFERER" => library_index_url }
      end
      assert_redirected_to library_index_url

      media_import = item.owned_media_imports.sole
      initial_payload = enqueued_jobs.find do |payload|
        payload[:job] == OwnedMediaBackupJob && payload[:args].first == media_import.id
      end
      assert initial_payload, "the Backup route should enqueue its durable polling job"
      initial_args = ActiveJob::Arguments.deserialize(initial_payload.fetch(:args))
      assert_equal [ media_import.id, media_import.poll_token ], initial_args
      enqueued_jobs.delete(initial_payload)

      extracted_metadata = MetadataExtractorService::Result.new(
        title: "Canonical Audible Integration",
        author: "Queue Test Author",
        year: nil,
        description: nil,
        narrator: nil,
        success: true
      )

      with_env("SHELFARR_LIBATION_IMPORT_ROOT" => import_root) do
        VCR.turned_off do
          stub_request(:post, "https://libation.test/v1/backups/B012345678")
            .to_return(
              status: 202,
              body: {
                jobId: "backup-1",
                status: "completed",
                artifactPath: "/data/Queue Test Author/Queue Test Author - Canonical Audible Integration.m4b"
              }.to_json
            )

          MetadataExtractorService.stub(:extract, extracted_metadata) do
            MetadataService.stub(:search, []) do
              LibraryPlatformClient.stub(:configured?, false) do
                assert_difference -> { Book.count }, 1 do
                  assert_difference -> { Upload.count }, 1 do
                    OwnedMediaBackupJob.perform_now(*initial_args)
                    OwnedMediaBackupJob.perform_now(*initial_args)
                  end

                  upload = media_import.reload.upload
                  upload_payload = enqueued_jobs.find do |payload|
                    payload[:job] == UploadProcessingJob && payload[:args] == [ upload.id ]
                  end
                  assert upload_payload, "artifact staging should enqueue upload processing"
                  UploadProcessingJob.perform_now(
                    *ActiveJob::Arguments.deserialize(upload_payload.fetch(:args))
                  )

                  watchdog_payload = enqueued_jobs.find do |payload|
                    payload[:job] == OwnedMediaBackupJob &&
                      payload[:args].first == media_import.id &&
                      payload[:args].second == media_import.reload.poll_token
                  end
                  assert watchdog_payload, "artifact staging should enqueue its recovery watchdog"
                  watchdog_args = ActiveJob::Arguments.deserialize(watchdog_payload.fetch(:args))
                  OwnedMediaBackupJob.perform_now(*watchdog_args)
                  OwnedMediaBackupJob.perform_now(*watchdog_args)
                end
              end
            end
          end

          assert_requested :post,
            "https://libation.test/v1/backups/B012345678",
            times: 1
        end
      end

      book = media_import.reload.upload.book
      assert media_import.completed?
      assert book.acquired?
      assert_equal book, item.reload.book
      assert item.downloaded?
      assert File.exist?(source_path), "Libation's source backup should remain preserved"

      get library_index_path

      assert_response :success
      assert_select "[data-owned-library-item-id='#{item.id}']", count: 0
      assert_select "[data-library-card][data-library-source='shelfarr'] a[href='#{library_path(book)}']", count: 1 do
        assert_select "h3", text: "Canonical Audible Integration"
        assert_select "span", text: "On server"
        assert_select "span", text: "Audible"
      end
    ensure
      upload_path = media_import&.reload&.upload&.file_path
      FileUtils.rm_f(upload_path) if upload_path.present?
    end
  end
end
