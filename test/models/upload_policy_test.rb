# frozen_string_literal: true

require "test_helper"

class UploadPolicyTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @admin = users(:two)
    @upload = Upload.new(user: @user)
  end

  test "regular users can view uploads when uploads are disabled" do
    policy = UploadPolicy.new(@user, @upload)

    assert policy.index?
    assert policy.show?
    refute policy.new?
    refute policy.create?
    refute policy.destroy?
    refute policy.retry?
  end

  test "regular users can upload when uploads are enabled" do
    SettingsService.set(:allow_user_uploads, true)
    policy = UploadPolicy.new(@user, @upload)

    assert policy.index?
    assert policy.show?
    assert policy.new?
    assert policy.create?
  end

  test "admins always have full upload access" do
    policy = UploadPolicy.new(@admin, @upload)

    assert policy.index?
    assert policy.show?
    assert policy.new?
    assert policy.create?
    assert policy.destroy?
    assert policy.retry?
  end

  test "scope returns all uploads for regular users" do
    own_upload = Upload.create!(
      user: @user,
      original_filename: "own.epub",
      file_path: "/tmp/own.epub",
      status: :pending
    )
    shared_upload = Upload.create!(
      user: @admin,
      original_filename: "shared.epub",
      file_path: "/tmp/shared.epub",
      status: :pending
    )

    resolved = UploadPolicy::Scope.new(@user, Upload).resolve

    assert_includes resolved, own_upload
    assert_includes resolved, shared_upload
  end
end
