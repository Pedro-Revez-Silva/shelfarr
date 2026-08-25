# frozen_string_literal: true

require "test_helper"
require "yaml"

class PrAuthorizationWorkflowTest < ActiveSupport::TestCase
  setup do
    @workflow = YAML.safe_load_file(
      Rails.root.join(".github/workflows/pr-authorization.yml"),
      aliases: true
    )
    @triggers = @workflow["on"] || @workflow.fetch(true)
    @job = @workflow.dig("jobs", "authorize")
    @step = @job.fetch("steps").sole
    @script = @step.dig("with", "script")
  end

  test "rechecks pull requests when their authorization can change" do
    assert_equal %w[opened reopened edited synchronize ready_for_review labeled unlabeled],
      @triggers.dig("pull_request_target", "types")
    assert_equal %w[unassigned closed], @triggers.dig("issues", "types")
    assert_equal false, @triggers.dig("workflow_dispatch", "inputs", "enforce", "default")
  end

  test "uses narrow permissions and never checks out contributor code" do
    assert_equal "read", @workflow.dig("permissions", "contents")
    assert_equal "write", @workflow.dig("permissions", "issues")
    assert_equal "write", @workflow.dig("permissions", "pull-requests")
    assert_equal "actions/github-script@ed597411d8f924073f98dfc5c65a23a2325f34cd",
      @step.fetch("uses")
    refute @job.fetch("steps").any? { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
  end

  test "requires every linked Shelfarr issue to be open and assigned to the author" do
    assert_includes @script, "closingIssuesReferences"
    assert_includes @script, "issue.repository.nameWithOwner.toLowerCase() === repositoryName"
    assert_includes @script, 'issue.state !== "OPEN" || !assignees.includes(normalizedAuthor)'
    assert_includes @script, "shelfarrIssues.length > 0 && unauthorizedIssues.length === 0"
  end

  test "exempts the owner, approved automation, and maintainer-adopted pull requests" do
    assert_includes @script, 'normalizedAuthor === owner.toLowerCase()'
    assert_includes @script, '"dependabot[bot]"'
    assert_includes @script, '"github-actions[bot]"'
    assert_includes @script, 'const maintainerAdoptedLabel = "maintainer-adopted"'
    assert_includes @script, "labels(first: 100)"
    assert_includes @script, "labels.includes(maintainerAdoptedLabel)"
    assert_includes @script, "explicitly adopted by a maintainer"
    refute_includes @script, "author_association"
  end

  test "explains and closes unauthorized pull requests idempotently" do
    assert_includes @script, "<!-- shelfarr-pr-authorization -->"
    assert_includes @script, "findPolicyComment"
    assert_includes @script, "upsertPolicyComment"
    assert_includes @script, 'core.warning(`DRY RUN:'
    assert_includes @script, 'state: "closed"'
    assert_includes @script, "Before reopening this pull request"
  end
end
