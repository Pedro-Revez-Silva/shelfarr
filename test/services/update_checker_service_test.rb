# frozen_string_literal: true

require "test_helper"

class UpdateCheckerServiceTest < ActiveSupport::TestCase
  GITHUB_REPO_API = "https://api.github.com/repos/Pedro-Revez-Silva/shelfarr"

  setup do
    use_release_channel("stable")
    @original_repo = SettingsService.get(:github_repo)
    SettingsService.set(:github_repo, "Pedro-Revez-Silva/shelfarr")
    UpdateCheckerService.clear_cache
    UpdateCheckerService.instance_variable_set(:@connection, nil)
  end

  teardown do
    SettingsService.set(:github_repo, @original_repo || "Pedro-Revez-Silva/shelfarr")
    UpdateCheckerService.clear_cache
    UpdateCheckerService.instance_variable_set(:@connection, nil)
  end

  test "a stable server is never offered a beta prerelease" do
    VCR.turned_off do
      stub_github_release("2026.11.16.1-beta", prerelease: true)

      UpdateCheckerService.stub(:current_version, "2026.11.09.1") do
        result = UpdateCheckerService.check(force: true)

        assert_not result.update_available?
        assert_nil result.latest_version
        assert_equal "No releases found", result.latest_message
      end
    end
  end

  test "a beta server is offered the highest beta or stable build wherever GitHub lists its tag" do
    use_release_channel("beta")
    VCR.turned_off do
      older = (1..1200).map { |number| "v2025.#{format('%02d', number % 12 + 1)}.#{format('%02d', number % 28 + 1)}.#{number}" }
      stub_server_tags("v2026.11.16.1-beta", *older, "v2026.11.30.1-rc", "v2026.12.01.1-beta-beta", "v2026.11.09.1", "v2026.11.23.1")
      stub_release_by_tag(release("2026.11.23.1"))

      UpdateCheckerService.stub(:current_version, "2026.11.16.1-beta") do
        result = UpdateCheckerService.check(force: true)

        assert result.update_available?
        assert_equal "2026.11.23.1", result.latest_version
        assert_equal "https://github.com/Pedro-Revez-Silva/shelfarr/releases/tag/v2026.11.23.1", result.release_url
      end
      assert_requested :get, "#{GITHUB_REPO_API}/git/matching-refs/tags/v20", times: 1
      assert_requested :get, %r{\A#{Regexp.escape(GITHUB_REPO_API)}/releases/tags/}, times: 1
    end
  end

  test "a beta server is offered a newer beta build than any stable one" do
    use_release_channel("beta")
    VCR.turned_off do
      stub_server_tags("v2026.11.01.1-beta", "v2026.11.09.1", "v2026.11.12.1-beta")
      stub_release_by_tag(release("2026.11.12.1-beta", prerelease: true))

      UpdateCheckerService.stub(:current_version, "2026.11.01.1-beta") do
        result = UpdateCheckerService.check(force: true)

        assert result.update_available?
        assert_equal "2026.11.12.1-beta", result.latest_version
      end
    end
  end

  test "a beta server skips newer tags without a published release and is offered the newest published build" do
    use_release_channel("beta")
    VCR.turned_off do
      stub_server_tags("v2026.11.01.1-beta", "v2026.11.09.1", "v2026.11.12.1-beta", "v2026.11.13.1-beta", "v2026.11.14.1-beta")
      stub_release_lookup("v2026.11.14.1-beta", status: 200, body: release("2026.11.14.1-beta", prerelease: true, draft: true))
      stub_release_lookup("v2026.11.13.1-beta", status: 404, body: { message: "Not Found" })
      stub_release_by_tag(release("2026.11.12.1-beta", prerelease: true))

      UpdateCheckerService.stub(:current_version, "2026.11.01.1-beta") do
        result = UpdateCheckerService.check(force: true)

        assert result.update_available?
        assert_equal "2026.11.12.1-beta", result.latest_version
      end
      assert_not_requested :get, "#{GITHUB_REPO_API}/releases/tags/v2026.11.09.1"
    end
  end

  test "a beta server is up to date when only unpublished tags are newer than its own release" do
    use_release_channel("beta")
    VCR.turned_off do
      stub_server_tags("v2026.11.09.1", "v2026.11.12.1-beta", "v2026.11.13.1-beta")
      stub_release_lookup("v2026.11.13.1-beta", status: 404, body: { message: "Not Found" })
      stub_release_by_tag(release("2026.11.12.1-beta", prerelease: true))

      UpdateCheckerService.stub(:current_version, "2026.11.12.1-beta") do
        result = UpdateCheckerService.check(force: true)

        assert_not result.update_available?
        assert_equal "2026.11.12.1-beta", result.latest_version
      end
    end
  end

  test "a beta server reports discovery it could not finish instead of an update result" do
    use_release_channel("beta")
    VCR.turned_off do
      {
        "Could not list release tags (HTTP 403)" => -> { stub_request(:get, "#{GITHUB_REPO_API}/git/matching-refs/tags/v20").to_return(status: 403, body: "{}") },
        "Could not read release v2026.11.12.1-beta (HTTP 500)" => lambda {
          stub_server_tags("v2026.11.09.1", "v2026.11.12.1-beta")
          stub_release_lookup("v2026.11.12.1-beta", status: 500, body: { message: "Server Error" })
        },
        "None of the newest 20 release tags has a published release" => lambda {
          tags = (1..21).map { |day| "v2026.12.#{format('%02d', day)}.1-beta" }
          stub_server_tags(*tags)
          tags.each { |tag| stub_release_lookup(tag, status: 404, body: { message: "Not Found" }) }
        }
      }.each do |message, stub_github|
        WebMock.reset!
        stub_github.call

        UpdateCheckerService.stub(:current_version, "2026.11.01.1-beta") do
          result = UpdateCheckerService.check(force: true)

          assert_not result.update_available?, message
          assert_nil result.latest_version, message
          assert_equal message, result.latest_message
        end
      end
    end
  end

  test "a beta server already on the newest build has no update" do
    use_release_channel("beta")
    VCR.turned_off do
      stub_server_tags("v2026.11.16.2-beta", "v2026.11.16.1-beta", "v2026.11.09.1")
      stub_release_by_tag(release("2026.11.16.2-beta", prerelease: true))

      UpdateCheckerService.stub(:current_version, "2026.11.16.2-beta") do
        result = UpdateCheckerService.check(force: true)

        assert_not result.update_available?
        assert_equal "2026.11.16.2-beta", result.latest_version
      end
    end
  end

  test "detects update when latest version is newer" do
    VCR.turned_off do
      stub_github_release("0.2.0", name: "v0.2.0", date: "2026-02-15T10:00:00Z")

      UpdateCheckerService.stub(:current_version, "0.1.0") do
        result = UpdateCheckerService.check(force: true)

        assert result.update_available?
        assert_equal "0.1.0", result.current_version
        assert_equal "0.2.0", result.latest_version
        assert_equal "v0.2.0", result.latest_message
      end
    end
  end

  test "calendar release supersedes the legacy semantic version" do
    VCR.turned_off do
      stub_github_release("2026.08.03.1", name: "Release 2026.08.03.1")

      UpdateCheckerService.stub(:current_version, "0.39.4") do
        result = UpdateCheckerService.check(force: true)

        assert result.update_available?
        assert_equal "2026.08.03.1", result.latest_version
      end
    end
  end

  test "compares calendar releases by date and release number" do
    VCR.turned_off do
      stub_github_release("2026.08.03.2")

      UpdateCheckerService.stub(:current_version, "2026.08.03.1") do
        result = UpdateCheckerService.check(force: true)

        assert result.update_available?
      end
    end
  end

  test "no update when versions match" do
    VCR.turned_off do
      stub_github_release("0.1.0")

      UpdateCheckerService.stub(:current_version, "0.1.0") do
        result = UpdateCheckerService.check(force: true)

        assert_not result.update_available?
        assert_equal "0.1.0", result.current_version
      end
    end
  end

  test "no update when current version is newer than latest" do
    VCR.turned_off do
      stub_github_release("0.1.0")

      UpdateCheckerService.stub(:current_version, "0.2.0") do
        result = UpdateCheckerService.check(force: true)

        assert_not result.update_available?
      end
    end
  end

  test "no update when current version is blank" do
    UpdateCheckerService.stub(:current_version, nil) do
      result = UpdateCheckerService.check(force: true)

      assert_not result.update_available?
      assert_equal "Version not available", result.latest_message
    end
  end

  test "no update when github repo is not configured" do
    SettingsService.set(:github_repo, "")

    UpdateCheckerService.stub(:current_version, "0.1.0") do
      result = UpdateCheckerService.check(force: true)

      assert_not result.update_available?
      assert_equal "GitHub repo not configured", result.latest_message
    end
  end

  test "no update when no releases exist" do
    VCR.turned_off do
      stub_request(:get, "https://api.github.com/repos/Pedro-Revez-Silva/shelfarr/releases/latest")
        .to_return(status: 404, body: { message: "Not Found" }.to_json, headers: { "Content-Type" => "application/json" })

      UpdateCheckerService.stub(:current_version, "0.1.0") do
        result = UpdateCheckerService.check(force: true)

        assert_not result.update_available?
        assert_equal "No releases found", result.latest_message
      end
    end
  end

  test "no update when github API returns error" do
    VCR.turned_off do
      stub_request(:get, "https://api.github.com/repos/Pedro-Revez-Silva/shelfarr/releases/latest")
        .to_return(status: 500, body: "", headers: { "Content-Type" => "application/json" })

      UpdateCheckerService.stub(:current_version, "0.1.0") do
        result = UpdateCheckerService.check(force: true)

        assert_not result.update_available?
        assert_equal "No releases found", result.latest_message
      end
    end
  end

  test "strips v prefix from tag name" do
    VCR.turned_off do
      stub_github_release("0.2.0")

      UpdateCheckerService.stub(:current_version, "0.1.0") do
        result = UpdateCheckerService.check(force: true)

        assert_equal "0.2.0", result.latest_version
      end
    end
  end

  test "includes release url" do
    VCR.turned_off do
      stub_github_release("0.2.0")

      UpdateCheckerService.stub(:current_version, "0.1.0") do
        result = UpdateCheckerService.check(force: true)

        assert_equal "https://github.com/Pedro-Revez-Silva/shelfarr/releases/tag/v0.2.0", result.release_url
      end
    end
  end

  test "includes release date as Time" do
    VCR.turned_off do
      stub_github_release("0.2.0", date: "2026-02-14T12:00:00Z")

      UpdateCheckerService.stub(:current_version, "0.1.0") do
        result = UpdateCheckerService.check(force: true)

        assert_instance_of Time, result.latest_date
        assert_equal Time.parse("2026-02-14T12:00:00Z"), result.latest_date
      end
    end
  end

  test "caches result" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    VCR.turned_off do
      stub_github_release("0.2.0")

      UpdateCheckerService.stub(:current_version, "0.1.0") do
        UpdateCheckerService.check(force: true)
      end

      cached = UpdateCheckerService.cached_result

      assert_not_nil cached
      assert_equal "0.1.0", cached.current_version
      assert_equal "0.2.0", cached.latest_version
    end
  ensure
    Rails.cache = original_cache
  end

  test "does not reuse cached result from a previous app version" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    VCR.turned_off do
      stub_github_release("0.5.1")

      UpdateCheckerService.stub(:current_version, "0.5.0") do
        stale_result = UpdateCheckerService.check(force: true)

        assert stale_result.update_available?
        assert_equal "0.5.0", stale_result.current_version
      end

      UpdateCheckerService.stub(:current_version, "0.5.1") do
        fresh_result = UpdateCheckerService.check

        assert_not fresh_result.update_available?
        assert_equal "0.5.1", fresh_result.current_version
        assert_equal "0.5.1", fresh_result.latest_version
      end
    end
  ensure
    Rails.cache = original_cache
  end

  test "cached_result ignores entries from older app versions" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    stale_result = UpdateCheckerService::Result.new(
      update_available: true,
      current_version: "0.5.0",
      latest_version: "0.5.1",
      latest_message: "v0.5.1",
      latest_date: Time.parse("2026-02-28T18:53:10Z"),
      release_url: "https://github.com/Pedro-Revez-Silva/shelfarr/releases/tag/v0.5.1"
    )

    Rails.cache.write(UpdateCheckerService.send(:cache_key_for, "0.5.0"), stale_result)

    UpdateCheckerService.stub(:current_version, "0.5.1") do
      assert_nil UpdateCheckerService.cached_result
    end
  ensure
    Rails.cache = original_cache
  end

  test "reads version from VERSION file" do
    result = UpdateCheckerService.send(:current_version)
    assert_equal "0.1.0", result
  end

  private

  def release(version, prerelease: false, draft: false)
    {
      "tag_name" => "v#{version}",
      "name" => "v#{version}",
      "draft" => draft,
      "prerelease" => prerelease,
      "published_at" => "2026-11-16T10:00:00Z",
      "html_url" => "https://github.com/Pedro-Revez-Silva/shelfarr/releases/tag/v#{version}"
    }
  end

  def stub_server_tags(*tags)
    refs = tags.map { |tag| { "ref" => "refs/tags/#{tag}", "object" => { "type" => "commit", "sha" => "0" * 40 } } }
    stub_request(:get, "#{GITHUB_REPO_API}/git/matching-refs/tags/v20")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: refs.to_json)
  end

  def stub_release_by_tag(release)
    stub_release_lookup(release.fetch("tag_name"), status: 200, body: release)
  end

  def stub_release_lookup(tag, status:, body:)
    stub_request(:get, "#{GITHUB_REPO_API}/releases/tags/#{tag}")
      .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end

  def stub_github_release(version, name: nil, date: "2026-02-15T10:00:00Z", prerelease: false)
    stub_request(:get, "https://api.github.com/repos/Pedro-Revez-Silva/shelfarr/releases/latest")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "tag_name" => "v#{version}",
          "name" => name || "v#{version}",
          "prerelease" => prerelease,
          "published_at" => date,
          "html_url" => "https://github.com/Pedro-Revez-Silva/shelfarr/releases/tag/v#{version}"
        }.to_json
      )
  end
end
