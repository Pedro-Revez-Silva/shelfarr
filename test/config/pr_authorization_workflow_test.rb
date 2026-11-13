# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
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

  test "exempts trusted bots when GraphQL omits the [bot] suffix" do
    %w[dependabot github-actions].each do |login|
      assert_authorization_exempt("login" => login, "__typename" => "Bot")
    end
  end

  test "exempts trusted bots reported with the REST login" do
    [ "dependabot[bot]", "github-actions[bot]", "Dependabot[bot]" ].each do |login|
      assert_authorization_exempt("login" => login, "__typename" => "Bot")
    end
  end

  test "does not exempt unlisted bots or a trusted bot name on a user account" do
    [
      { "login" => "untrusted-bot", "__typename" => "Bot" },
      { "login" => "dependabot", "__typename" => "User" },
      { "login" => "github-actions" }
    ].each do |author|
      assert_authorization_closed(author)
    end
  end

  private

  def assert_authorization_exempt(author)
    outcome = authorization_outcome(author)
    login = author.fetch("login")

    assert_includes outcome.fetch("logs"), "PR #704: @#{login} is exempt from issue assignment."
    assert_empty outcome.fetch("actions"), outcome.fetch("logs").join("\n")
  end

  def assert_authorization_closed(author)
    outcome = authorization_outcome(author)
    login = author.fetch("login")

    assert_includes outcome.fetch("logs"), "Closed unauthorized PR #704 from @#{login}."
    assert_includes outcome.fetch("actions").map { |action| action.fetch("type") }, "close"
  end

  def authorization_outcome(author)
    stdout, stderr, status = Open3.capture3(
      "node", "--input-type=module", stdin_data: authorization_harness(author)
    )
    assert status.success?, "#{stderr}\n#{stdout}"

    JSON.parse(stdout)
  end

  # github-script evaluates the workflow as an async function with these arguments.
  # Project only author fields the query selects; GraphQL omits the rest.
  def authorization_harness(author)
    <<~JS
      const fixtureAuthor = #{JSON.generate(author)};
      const script = #{JSON.generate(@script)};
      const logs = [];
      const actions = [];
      const github = {
        async graphql(query) {
          const match = String(query).match(/author\\s*\\{([^}]*)\\}/);
          if (!match) throw new Error("pull request query did not select author");
          const selected = match[1];
          const projected = {};
          if (selected.includes("login") && Object.hasOwn(fixtureAuthor, "login")) {
            projected.login = fixtureAuthor.login;
          }
          if (selected.includes("__typename") && Object.hasOwn(fixtureAuthor, "__typename")) {
            projected.__typename = fixtureAuthor.__typename;
          }
          return {
            repository: {
              pullRequest: {
                number: 704,
                state: "OPEN",
                author: projected,
                labels: { nodes: [] },
                closingIssuesReferences: { nodes: [] },
              },
            },
          };
        },
        async paginate() {
          return [];
        },
        rest: {
          issues: {
            async listComments() {
              return { data: [] };
            },
            async createComment() {
              actions.push({ type: "createComment" });
            },
            async updateComment() {
              actions.push({ type: "updateComment" });
            },
          },
          pulls: {
            async update(args) {
              actions.push({ type: "close", state: args.state });
            },
            async list() {
              return { data: [] };
            },
          },
        },
      };
      const context = {
        repo: { owner: "maintainer", repo: "shelfarr" },
        eventName: "pull_request_target",
        payload: {
          pull_request: { number: 704 },
          repository: { default_branch: "main" },
        },
      };
      const core = {
        info(message) {
          logs.push(String(message));
        },
        warning(message) {
          logs.push(String(message));
        },
      };
      const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
      await new AsyncFunction("github", "context", "core", script)(github, context, core);
      process.stdout.write(JSON.stringify({ logs, actions }));
    JS
  end
end
