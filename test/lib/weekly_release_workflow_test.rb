# frozen_string_literal: true

require "test_helper"
require "open3"

class WeeklyReleaseWorkflowTest < ActiveSupport::TestCase
  WORKFLOW = Rails.root.join(".github/workflows/docker.yml")
  IMAGE = "ghcr.io/pedro-revez-silva/shelfarr"
  COMPANION_IMAGE = "ghcr.io/pedro-revez-silva/shelfarr-libation"

  setup do
    @workflow = YAML.safe_load(WORKFLOW.read, aliases: true)
    @directory = Dir.mktmpdir("weekly-release")
    @today = Time.now.utc.strftime("%Y.%m.%d")
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "a beta source publishes beta-only image tags and a prerelease that never becomes latest" do
    checkout = source_checkout(channel: "beta", existing_tags: [ "v#{@today}.1" ])

    outputs = plan(checkout)

    assert_equal "true", outputs.fetch("should_release")
    assert_equal "v#{@today}.2-beta", outputs.fetch("tag")
    assert_equal [ "#{IMAGE}:#{@today}.2-beta", "#{IMAGE}:beta" ], image_tags("meta", IMAGE, outputs)
    assert_equal [ "#{COMPANION_IMAGE}:#{@today}.2-beta", "#{COMPANION_IMAGE}:beta" ],
      image_tags("libation_meta", COMPANION_IMAGE, outputs)

    release = create_release(checkout, outputs)

    assert_equal [ "release", "create", "v#{@today}.2-beta", "--target", git(checkout, "rev-parse", "HEAD"),
      "--title", "Shelfarr 1.0 Beta (build #{@today}.2-beta)", "--notes-file", "release-body.txt",
      "--prerelease", "--latest=false" ], release.fetch(:arguments)
    assert_includes release.fetch(:body), "- #{IMAGE}:beta\n"
    assert_includes release.fetch(:body), "- #{COMPANION_IMAGE}:beta\n"
    assert_no_match(/:latest$/, release.fetch(:body))
  end

  test "a source deliberately promoted to stable moves latest and publishes the stable release" do
    checkout = source_checkout(channel: "stable", existing_tags: [ "v#{@today}.1-beta" ])

    outputs = plan(checkout)

    assert_equal "v#{@today}.2", outputs.fetch("tag")
    assert_equal [ "#{IMAGE}:#{@today}.2", "#{IMAGE}:latest" ], image_tags("meta", IMAGE, outputs)
    assert_equal [ "#{COMPANION_IMAGE}:#{@today}.2", "#{COMPANION_IMAGE}:latest" ],
      image_tags("libation_meta", COMPANION_IMAGE, outputs)

    release = create_release(checkout, outputs)

    assert_equal [ "release", "create", "v#{@today}.2", "--target", git(checkout, "rev-parse", "HEAD"),
      "--title", "Release #{@today}.2", "--notes-file", "release-body.txt", "--latest" ], release.fetch(:arguments)
  end

  test "an unknown or missing channel publishes nothing" do
    [ "channel: nightly\nseries: \"1.0\"\n", nil ].each do |source|
      checkout = source_checkout(channel: "beta", existing_tags: [])
      channel_file = File.join(checkout, "config/release_channel.yml")
      source ? File.write(channel_file, source) : File.delete(channel_file)
      commit(checkout, "change the channel")

      output, status, written = run_plan_step(checkout)

      assert_not status.success?, output
      assert_equal "", written
    end
  end

  test "an unchanged source since the last release is skipped" do
    checkout = source_checkout(channel: "beta", existing_tags: [])
    git(checkout, "tag", "v#{@today}.1-beta")
    push_tags(checkout)

    outputs = plan(checkout)

    assert_equal "false", outputs.fetch("should_release")
    assert_equal "v#{@today}.1-beta", outputs.fetch("previous_tag")
    assert_equal "", outputs.fetch("tag")
  end

  private

  def source_checkout(channel:, existing_tags:)
    checkout = File.join(@directory, "checkout-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(checkout)
    %w[bin lib config].each { |directory| FileUtils.cp_r(Rails.root.join(directory), checkout) }
    File.write(File.join(checkout, "config/release_channel.yml"), "channel: #{channel}\nseries: \"1.0\"\n")
    git(checkout, "init", "--quiet", "--initial-branch", "main")
    commit(checkout, "previous release")
    git(checkout, "tag", "v2026.01.05.1")
    existing_tags.each { |tag| git(checkout, "tag", tag) }
    File.write(File.join(checkout, "CHANGE"), "new work\n")
    commit(checkout, "new work")
    origin = "#{checkout}.git"
    git(@directory, "clone", "--quiet", "--bare", checkout, origin)
    git(checkout, "remote", "add", "origin", origin)
    checkout
  end

  def push_tags(checkout)
    git(checkout, "push", "--quiet", "--tags", "origin")
  end

  def commit(checkout, message)
    git(checkout, "add", "--all")
    git(checkout, "commit", "--quiet", "--allow-empty", "--message", message)
  end

  def plan(checkout)
    output, status, written = run_plan_step(checkout)
    assert status.success?, output
    written.lines.to_h { |line| line.chomp.split("=", 2) }
  end

  def run_plan_step(checkout)
    output_file = File.join(@directory, "plan-output-#{SecureRandom.hex(4)}")
    File.write(output_file, "")
    output, status = run_step(step("plan", "Plan release"), checkout, "GITHUB_OUTPUT" => output_file)
    [ output, status, File.read(output_file) ]
  end

  def image_tags(step_id, image, outputs)
    tags = step("docker", id: step_id).dig("with", "tags")
    expand(tags, outputs).lines.map(&:strip).reject(&:empty?).map do |line|
      "#{image}:#{line.delete_prefix('type=raw,value=')}"
    end
  end

  def create_release(checkout, outputs)
    tools = File.join(@directory, "tools")
    FileUtils.mkdir_p(tools)
    arguments_file = File.join(@directory, "gh-arguments")
    File.write(File.join(tools, "gh"), <<~SH)
      #!/bin/sh
      for argument in "$@"; do printf '%s\\n' "$argument"; done > #{arguments_file}
    SH
    FileUtils.chmod(0o755, File.join(tools, "gh"))
    publish = step("publish-release", "Create tag and GitHub release after paired images")
    environment = publish.fetch("env").transform_values { |value| expand(value.to_s, outputs) }
    environment["GITHUB_REPOSITORY"] = "Pedro-Revez-Silva/shelfarr"
    environment["PATH"] = "#{tools}:#{ENV.fetch('PATH')}"

    output, status = run_step(publish, checkout, environment)
    assert status.success?, output
    { arguments: File.read(arguments_file).lines.map(&:chomp), body: File.read(File.join(checkout, "release-body.txt")) }
  end

  def step(job, name = nil, id: nil)
    @workflow.dig("jobs", job, "steps").find { |candidate| name ? candidate["name"] == name : candidate["id"] == id } ||
      flunk("#{job} has no step #{name || id}")
  end

  def expand(text, outputs)
    text.gsub(/\$\{\{\s*([^}]+?)\s*\}\}/) do
      expression = Regexp.last_match(1)
      case expression
      when /\Aneeds\.plan\.outputs\.(\w+)\z/ then outputs.fetch(Regexp.last_match(1))
      when "secrets.GITHUB_TOKEN" then "test-token"
      else flunk("Unexpected workflow expression #{expression}")
      end
    end
  end

  def run_step(step, checkout, environment)
    Open3.capture2e(git_environment.merge(environment), "bash", "--noprofile", "--norc", "-eo", "pipefail", "-c",
      step.fetch("run"), chdir: checkout)
  end

  def git(directory, *arguments)
    output, status = Open3.capture2e(git_environment, "git", *arguments, chdir: directory)
    assert status.success?, output
    output.strip
  end

  def git_environment
    {
      "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_AUTHOR_NAME" => "Release Test",
      "GIT_AUTHOR_EMAIL" => "release-test@example.invalid",
      "GIT_COMMITTER_NAME" => "Release Test",
      "GIT_COMMITTER_EMAIL" => "release-test@example.invalid"
    }
  end
end
