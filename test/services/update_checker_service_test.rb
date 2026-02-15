# frozen_string_literal: true

require "test_helper"

class UpdateCheckerServiceTest < ActiveSupport::TestCase
  setup do
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

  test "reads version from VERSION file" do
    result = UpdateCheckerService.send(:current_version)
    assert_equal "0.1.0", result
  end

  private

  def stub_github_release(version, name: nil, date: "2026-02-15T10:00:00Z")
    stub_request(:get, "https://api.github.com/repos/Pedro-Revez-Silva/shelfarr/releases/latest")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "tag_name" => "v#{version}",
          "name" => name || "v#{version}",
          "published_at" => date,
          "html_url" => "https://github.com/Pedro-Revez-Silva/shelfarr/releases/tag/v#{version}"
        }.to_json
      )
  end
end
