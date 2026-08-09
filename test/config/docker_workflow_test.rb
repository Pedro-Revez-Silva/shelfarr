# frozen_string_literal: true

require "test_helper"
require "json"
require "yaml"

class DockerWorkflowTest < ActiveSupport::TestCase
  setup do
    @workflow = YAML.safe_load_file(
      Rails.root.join(".github/workflows/docker.yml"),
      aliases: true
    )
    @triggers = @workflow["on"] || @workflow.fetch(true)
    @jobs = @workflow.fetch("jobs")
  end

  test "release runs weekly or manually and skips main when it is unchanged" do
    refute @triggers.key?("push")
    refute @triggers.key?("pull_request")
    assert @triggers.key?("workflow_dispatch")
    assert_equal [ "17 4 * * 1" ], @triggers.fetch("schedule").pluck("cron")

    plan_job = @jobs.fetch("plan")
    checkout = plan_job.fetch("steps").find { |step| step["name"] == "Checkout main" }
    planner = plan_job.fetch("steps").find { |step| step["name"] == "Plan release" }.fetch("run")

    assert_equal "main", checkout.dig("with", "ref")
    assert_equal "read", plan_job.dig("permissions", "contents")
    assert_includes planner, "git diff --quiet"
    assert_includes planner, "date -u +'%Y.%m.%d'"
    assert_includes planner, 'version="${date_version}.${release_number}"'
    assert_includes planner, 'git tag --list "v${date_version}.*"'
    assert_includes planner, 'echo "should_release=false"'
    assert_equal "weekly-release-main", @workflow.dig("concurrency", "group")
    assert_equal false, @workflow.dig("concurrency", "cancel-in-progress")
  end

  test "calendar versioning does not derive a bump from commit messages" do
    workflow_source = Rails.root.join(".github/workflows/docker.yml").read
    planner = @jobs.fetch("plan").fetch("steps").find do |step|
      step["name"] == "Plan release"
    end.fetch("run")

    refute_includes workflow_source, "github-tag-action"
    refute_includes workflow_source, "default_bump"
    refute_includes workflow_source, "new_version"
    refute_includes workflow_source, "new_tag"
    refute_includes planner, "git log"
  end

  test "release waits for full validation, architecture contracts, and paired Docker images" do
    validation_commands = @jobs.fetch("validate").fetch("steps").filter_map { |step| step["run"] }
    filesystem_job = @jobs.fetch("filesystem-contracts")
    filesystem_commands = filesystem_job.fetch("steps").filter_map { |step| step["run"] }

    assert validation_commands.any? { |command| command.include?("bin/quality push") }
    assert validation_commands.any? { |command| command.include?("bin/bundler-audit --update") }
    assert_equal "ubuntu-latest", @jobs.dig("validate", "runs-on")
    assert filesystem_commands.any? { |command| command.include?("cifs-utils") }
    assert filesystem_commands.any? { |command| command.include?("cifs-smoke.sh") }
    assert_equal %w[ubuntu-latest ubuntu-24.04-arm],
      filesystem_job.dig("strategy", "matrix", "runner")

    docker_job = @jobs.fetch("docker")
    assert_equal %w[plan validate filesystem-contracts], docker_job.fetch("needs")
    assert_includes docker_job.fetch("if"), "needs.plan.outputs.should_release == 'true'"

    docker_steps = docker_job.fetch("steps")
    candidate_steps = docker_steps.select { |step| step["name"]&.match?(/Build .* candidate\z/) }
    promotion_steps = docker_steps.select { |step| step["name"]&.start_with?("Promote exact ") }
    assert_equal 2, candidate_steps.size
    assert_equal 2, promotion_steps.size
    assert candidate_steps.all? { |step| step.dig("with", "push") == true }
    assert promotion_steps.none? { |step| step.key?("if") }
    assert promotion_steps.all? { |step| step.fetch("run").include?("docker buildx imagetools create") }
    assert promotion_steps.all? { |step| step.dig("env", "CANDIDATE_DIGEST").include?("outputs.digest") }

    last_candidate_index = candidate_steps.map { |step| docker_steps.index(step) }.max
    first_promotion_index = promotion_steps.map { |step| docker_steps.index(step) }.min
    assert_operator first_promotion_index, :>, last_candidate_index,
      "no stable image tag may move until both exact paired candidates build"
    assert_equal "Promote exact Libation companion candidate", promotion_steps.first.fetch("name")
    assert_equal "Promote exact Shelfarr candidate", promotion_steps.last.fetch("name")

    release_job = @jobs.fetch("publish-release")
    assert_equal %w[plan validate docker], release_job.fetch("needs")
    assert_equal "write", release_job.dig("permissions", "contents")
    release_step = release_job.fetch("steps").find do |step|
      step["name"] == "Create tag and GitHub release after paired images"
    end
    tag_verification_step = release_job.fetch("steps").find do |step|
      step["name"] == "Verify release tag and release target"
    end
    assert_includes release_step.fetch("run"), 'gh release create "${TAG}"'
    assert_includes release_step.fetch("run"), '--target "${HEAD_SHA}"'
    assert_includes tag_verification_step.fetch("run"), "git/ref/tags/${RELEASE_TAG}"
    assert_includes tag_verification_step.fetch("run"), 'test "${tag_commit}" = "${HEAD_SHA}"'
    assert_includes tag_verification_step.fetch("run"), "gh release view"

    refute @jobs.values.flat_map { |job| job.fetch("steps", []) }.any? { |step|
      step["uses"]&.start_with?("softprops/action-gh-release@")
    }
  end

  test "every release job uses the commit selected by the planner" do
    %w[validate filesystem-contracts docker publish-release].each do |job_name|
      checkout = @jobs.fetch(job_name).fetch("steps").find do |step|
        step["name"] == "Checkout planned commit"
      end

      assert_equal "${{ needs.plan.outputs.head_sha }}", checkout.dig("with", "ref")
    end
  end

  test "all workflow actions use immutable commit references" do
    %w[ci.yml docker.yml].each do |filename|
      workflow = YAML.safe_load_file(
        Rails.root.join(".github/workflows", filename),
        aliases: true
      )

      workflow.fetch("jobs").each_value do |job|
        job.fetch("steps", []).each do |step|
          reference = step["uses"]
          next if reference.blank? || reference.start_with?("./")

          assert_match %r{\A[^@]+@[0-9a-f]{40}\z}, reference,
            "#{filename} must pin #{reference.inspect} to a full commit SHA"
        end
      end
    end
  end

  test "companion validation uses locked dependencies and formatting" do
    validation_steps = @jobs.fetch("validate").fetch("steps")
    commands = validation_steps.filter_map { |step| step["run"] }
    setup_step = validation_steps.find { |step| step["name"] == "Set up .NET for companion tests" }

    assert commands.any? { |command| command.include?("dotnet restore") && command.include?("--locked-mode") }
    assert commands.any? { |command| command.include?("dotnet format") && command.include?("--verify-no-changes") }
    assert commands.any? { |command| command.include?("dotnet test") && command.include?("--no-restore") }
    assert_equal "10.0.302", setup_step.dig("with", "dotnet-version")
  end

  test "pull request CI keeps companion and container validation without publishing" do
    workflow = YAML.safe_load_file(
      Rails.root.join(".github/workflows/ci.yml"),
      aliases: true
    )
    jobs = workflow.fetch("jobs")
    companion_commands = jobs.fetch("companion").fetch("steps").filter_map { |step| step["run"] }
    filesystem_commands = jobs.fetch("filesystem-contracts").fetch("steps").filter_map { |step| step["run"] }
    container_build = jobs.fetch("container").fetch("steps").find do |step|
      step["name"] == "Build Shelfarr image"
    end

    assert companion_commands.any? { |command| command.include?("dotnet restore") && command.include?("--locked-mode") }
    assert companion_commands.any? { |command| command.include?("dotnet format") && command.include?("--verify-no-changes") }
    assert companion_commands.any? { |command| command.include?("dotnet test") && command.include?("--no-restore") }
    assert companion_commands.any? { |command| command.include?("container-smoke.sh") }
    assert filesystem_commands.any? { |command| command.include?("cifs-utils") }
    assert filesystem_commands.any? { |command| command.include?("cifs-smoke.sh") }
    assert_equal [ "quality" ], jobs.fetch("filesystem-contracts").fetch("needs")
    assert_includes jobs.dig("filesystem-contracts", "strategy", "matrix", "runner"), "ubuntu-24.04-arm"
    assert_includes jobs.fetch("container").fetch("needs"), "filesystem-contracts"
    assert_equal false, container_build.dig("with", "push")
  end

  test "companion build inputs and upstream source are immutable" do
    dockerfile = Rails.root.join("services/libation_companion/Dockerfile").read
    notice = Rails.root.join("services/libation_companion/THIRD_PARTY_NOTICES.md").read
    sdk = JSON.parse(Rails.root.join("services/libation_companion/global.json").read)
    packaged_license = Rails.root.join(
      "services/libation_companion/LICENSES/Libation-GPL-3.0.txt"
    ).binread

    assert dockerfile.start_with?(
      "# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e"
    )
    assert_includes dockerfile,
      "mcr.microsoft.com/dotnet/sdk:10.0.302-noble@sha256:ed034a8bf0b24ded0cbbac07e17825d8e9ebfe21e308191d0f7421eaf5ad4664"
    assert_includes dockerfile,
      "rmcrackan/libation:13.5.1@sha256:71b9db4bbda7d7e14bb9f5efcdcfe980915c90867599bc0d512d958069fb3da0"
    assert_includes dockerfile, "07c2f2b2a1deb8c57601c2b131aba30c95be3097"
    assert_includes dockerfile, "Libation-13.5.1-source.tar.gz"
    assert_equal "10.0.302", sdk.dig("sdk", "version")
    assert_equal "disable", sdk.dig("sdk", "rollForward")
    assert_equal Rails.root.join("LICENSE").binread, packaged_license

    assert_includes notice, "Version: `13.5.1`"
    assert_includes notice,
      "Manifest digest: `sha256:71b9db4bbda7d7e14bb9f5efcdcfe980915c90867599bc0d512d958069fb3da0`"
    assert_includes notice, "Source commit: `07c2f2b2a1deb8c57601c2b131aba30c95be3097`"
    assert_includes notice,
      "Source snapshot SHA-256: `7391b9e4e34375e5d134932246ce0a50e0561efe1a24c2a3aa8f32a1217fac9f`"
  end

  test "release build helper images are pinned" do
    docker_steps = @jobs.fetch("docker").fetch("steps")
    qemu = docker_steps.find { |step| step["name"] == "Set up QEMU" }
    buildx = docker_steps.find { |step| step["name"] == "Set up Docker Buildx" }

    assert_match %r{\Atonistiigi/binfmt:[^@]+@sha256:[0-9a-f]{64}\z}, qemu.dig("with", "image")
    assert_equal "arm64", qemu.dig("with", "platforms")
    assert_match %r{\Aimage=moby/buildkit:[^@]+@sha256:[0-9a-f]{64}\z},
      buildx.dig("with", "driver-opts")
  end
end
