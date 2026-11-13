# frozen_string_literal: true

require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
  end

  test "index links to Audible Backup beta" do
    get admin_root_url

    assert_response :success
    assert_select "a[href='#{admin_owned_library_connections_path}']", text: "Audible Backup (Beta)"
  end

  test "run_health_check requires admin" do
    sign_out
    post admin_run_health_check_url
    assert_response :redirect
  end

  test "run_health_check enqueues job and redirects with notice" do
    assert_enqueued_with(job: HealthCheckJob) do
      post admin_run_health_check_url
    end

    assert_redirected_to admin_root_path
    assert_equal "Health check started. Results will appear shortly.", flash[:notice]
  end

  test "run_health_check redirects with generic alert on failure" do
    HealthCheckJob.stub(:perform_later, ->(*) { raise "Redis connection refused" }) do
      post admin_run_health_check_url
    end

    assert_redirected_to admin_root_path
    assert_equal "Health check failed. Check logs for details.", flash[:alert]
  end

  test "the overview turns health problems into links to the setting that fixes them" do
    SystemHealth.for_service("indexer").check_failed!(message: "Failed to connect to Prowlarr")
    SystemHealth.for_service("download_client").check_failed!(message: "qBittorrent refused the login", degraded: true)
    SystemHealth.for_service("hardcover").check_succeeded!(message: "Connection successful")

    get admin_root_url

    assert_response :success
    assert_select "h1", "Server overview"
    issues = css_select("section[aria-labelledby='attention-heading'] li").map do |item|
      [ item.at_css("p").text.squish, item.at_css("a")&.[]("href") ]
    end
    assert_equal [
      [ "Indexer is down", admin_settings_path(anchor: "settings-section-indexer") ],
      [ "Download client is degraded", admin_download_clients_path ],
      [ "2 requests need attention", requests_path(attention: "true") ]
    ], issues
    assert_select "#system-health a[href='#{admin_settings_path(anchor: "settings-section-hardcover")}']", text: "Hardcover settings"
    assert_select "#system-health a[href='#{admin_settings_path(anchor: "settings-section-paths")}']", text: "Folder settings", count: 2
  end

  test "the overview says when nothing needs attention" do
    Request.update_all(attention_needed: false)
    SystemHealth.for_service("indexer").check_succeeded!(message: "Connection successful")

    get admin_root_url

    assert_select "section[aria-labelledby='attention-heading'] li", count: 0
    assert_select "section[aria-labelledby='attention-heading'] p", text: "Nothing needs attention from the last health check."
  end

  test "the release card names the beta channel, its build and how to go back without contacting GitHub" do
    use_release_channel("beta")
    get admin_root_url

    assert_select "#release p", text: "Shelfarr 1.0 Beta"
    assert_select "#release dd", text: File.read(Rails.root.join("VERSION")).strip
    assert_select "#release dd", text: "Newest beta or stable build"
    assert_select "#release dd", text: "Not checked yet"
    assert_select "#release pre", text: "docker pull ghcr.io/pedro-revez-silva/shelfarr:beta"
    assert_select "#release a[href='https://github.com/Pedro-Revez-Silva/shelfarr/blob/main/docs/releases.md']"
  end

  test "a stable release card follows stable images" do
    use_release_channel("stable")
    get admin_root_url

    assert_select "#release p", text: "Shelfarr 1.0"
    assert_select "#release dd", text: "Stable releases only"
    assert_select "#release pre", text: "docker pull ghcr.io/pedro-revez-silva/shelfarr:latest"
  end

  test "the overview links every settings category to its tab" do
    get admin_root_url

    hrefs = css_select("section[aria-labelledby='settings-heading'] ul a").map { |link| link["href"] }
    assert_equal %w[search downloads integrations system security].map { |tab| admin_settings_path(anchor: tab) }, hrefs
  end

  test "ordinary users cannot open the overview" do
    sign_in_as(users(:one))

    get admin_root_url

    assert_redirected_to root_path
  end

  test "checking for updates says when the check could not finish" do
    failed = UpdateCheckerService::Result.new(update_available: false, current_version: "2026.11.01.1-beta",
      latest_version: nil, latest_message: "Could not list release tags (HTTP 403)", latest_date: nil, release_url: nil)
    current = UpdateCheckerService::Result.new(update_available: false, current_version: "2026.11.12.1-beta",
      latest_version: "2026.11.12.1-beta", latest_message: "v2026.11.12.1-beta", latest_date: nil, release_url: nil)

    UpdateCheckerService.stub(:check, failed) { post admin_check_updates_url }
    assert_redirected_to admin_root_path
    assert_equal "Couldn't check for updates: Could not list release tags (HTTP 403)", flash[:notice]

    UpdateCheckerService.stub(:check, current) { post admin_check_updates_url }
    assert_equal "You're running the latest version (2026.11.12.1-beta)", flash[:notice]
  end
end
