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
    @jobs = @workflow.fetch("jobs")
  end

  test "release waits for the full validation gate and paired Docker images" do
    validation_commands = @jobs.fetch("validate").fetch("steps").filter_map { |step| step["run"] }

    assert validation_commands.any? { |command| command.include?("bin/quality push") }
    assert validation_commands.any? { |command| command.include?("bin/bundler-audit --update") }

    docker_job = @jobs.fetch("docker")
    assert_equal %w[validate version], docker_job.fetch("needs")
    assert_includes docker_job.fetch("if"), "always()"
    assert_includes docker_job.fetch("if"), "needs.version.result == 'skipped'"

    docker_steps = docker_job.fetch("steps")
    candidate_steps = docker_steps.select { |step| step["name"]&.match?(/Build .* candidate\z/) }
    promotion_steps = docker_steps.select { |step| step["name"]&.start_with?("Promote exact ") }
    assert_equal 2, candidate_steps.size
    assert_equal 2, promotion_steps.size
    assert candidate_steps.all? { |step|
      step.dig("with", "push").include?("github.event_name != 'pull_request'")
    }
    assert promotion_steps.all? { |step|
      step.fetch("if").include?("github.event_name != 'pull_request'")
    }
    assert promotion_steps.all? { |step| step.fetch("run").include?("docker buildx imagetools create") }
    assert promotion_steps.all? { |step| step.dig("env", "CANDIDATE_DIGEST").include?("outputs.digest") }

    last_candidate_index = candidate_steps.map { |step| docker_steps.index(step) }.max
    first_promotion_index = promotion_steps.map { |step| docker_steps.index(step) }.min
    assert_operator first_promotion_index, :>, last_candidate_index,
      "no stable image tag may move until both exact paired candidates build"
    assert_equal "Promote exact Libation companion candidate", promotion_steps.first.fetch("name")
    assert_equal "Promote exact Shelfarr candidate", promotion_steps.last.fetch("name")

    release_job = @jobs.fetch("publish-release")
    assert_equal %w[validate version docker], release_job.fetch("needs")
    assert_includes release_job.fetch("if"), "needs.docker.result == 'success'"
    assert release_job.fetch("steps").any? { |step|
      step["uses"]&.start_with?("softprops/action-gh-release@")
    }

    version_step = @jobs.fetch("version").fetch("steps").find do |step|
      step["uses"]&.start_with?("mathieudutour/github-tag-action@")
    end
    assert_equal true, version_step.dig("with", "dry_run")
    assert_equal true, version_step.dig("with", "fetch_all_tags")
    assert_equal "read", @jobs.fetch("version").dig("permissions", "contents")

    release_step = release_job.fetch("steps").find do |step|
      step["uses"]&.start_with?("softprops/action-gh-release@")
    end
    tag_verification_step = release_job.fetch("steps").find do |step|
      step["name"] == "Verify release tag and release target"
    end
    assert_equal "${{ github.sha }}", release_step.dig("with", "target_commitish")
    assert_includes tag_verification_step.fetch("run"), "git/ref/tags/${RELEASE_TAG}"
    assert_includes tag_verification_step.fetch("run"), 'test "${tag_commit}" = "${GITHUB_SHA}"'
    assert_includes tag_verification_step.fetch("run"), "gh release view"
    assert_equal false, @workflow.dig("concurrency", "cancel-in-progress")

    refute @jobs.fetch("version").fetch("steps").any? { |step|
      step["uses"]&.start_with?("softprops/action-gh-release@")
    }
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
    assert_equal "true", @workflow.dig("env", "FORCE_JAVASCRIPT_ACTIONS_TO_NODE24")
  end
end
