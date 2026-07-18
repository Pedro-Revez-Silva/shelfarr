# frozen_string_literal: true

require "test_helper"

class UploadCreatorTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @request = requests(:pending_request)
    @tempfile = Tempfile.new([ "owned-request-upload", ".epub" ])
    @tempfile.binmode
    @tempfile.write("private purchased ebook")
    @tempfile.rewind
    @uploaded_file = ActionDispatch::Http::UploadedFile.new(
      tempfile: @tempfile,
      filename: "Purchased Ebook.epub",
      type: "application/epub+zip"
    )
  end

  teardown do
    @tempfile&.close!
  end

  test "API cancellation after ingress staging wins before request upload attachment" do
    staged_path = nil
    original_stage = UploadImportFileService.method(:stage_ingress!)
    interleaved_stage = lambda do |source, basename, max_bytes:|
      result = original_stage.call(source, basename, max_bytes: max_bytes)
      staged_path = result.first
      @request.cancel!
      result
    end

    result = UploadImportFileService.stub(:stage_ingress!, interleaved_stage) do
      assert_no_difference "Upload.count" do
        UploadCreator.call(user: @user, uploaded_file: @uploaded_file, request: @request)
      end
    end

    assert_not result.success?
    assert_match(/no longer open/i, result.alert)
    assert @request.reload.failed?
    assert_not File.exist?(staged_path), "rejected attachment must remove its private ingress copy"
  ensure
    UploadImportFileService.discard_ingress!(staged_path) if staged_path
  end

  test "web destruction after ingress staging wins before request upload attachment" do
    staged_path = nil
    original_stage = UploadImportFileService.method(:stage_ingress!)
    interleaved_stage = lambda do |source, basename, max_bytes:|
      result = original_stage.call(source, basename, max_bytes: max_bytes)
      staged_path = result.first
      @request.destroy!
      result
    end

    result = UploadImportFileService.stub(:stage_ingress!, interleaved_stage) do
      assert_no_difference "Upload.count" do
        UploadCreator.call(user: @user, uploaded_file: @uploaded_file, request: @request)
      end
    end

    assert_not result.success?
    assert_match(/no longer available/i, result.alert)
    assert_not Request.exists?(@request.id)
    assert_not File.exist?(staged_path), "rejected attachment must remove its private ingress copy"
  ensure
    UploadImportFileService.discard_ingress!(staged_path) if staged_path
  end

  test "an attached upload wins before API cancellation and remains durable" do
    result = UploadCreator.call(
      user: @user,
      uploaded_file: @uploaded_file,
      request: @request
    )
    upload = result.upload

    assert result.success?
    error = assert_raises(Request::CancellationBlockedError) { @request.cancel! }
    assert_match(/upload.*in progress/i, error.message)
    assert @request.reload.pending?
    assert upload.reload.pending?
    assert File.exist?(upload.file_path)
  ensure
    upload&.destroy!
  end
end
