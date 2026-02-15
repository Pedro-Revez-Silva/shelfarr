# frozen_string_literal: true

# Checks GitHub releases for available updates
class UpdateCheckerService
  class Error < StandardError; end

  Result = Data.define(:update_available, :current_version, :latest_version, :latest_message, :latest_date, :release_url) do
    def update_available?
      update_available
    end
  end

  CACHE_KEY = "shelfarr:update_check"
  CACHE_TTL = 1.hour

  class << self
    # Check for updates (cached)
    def check(force: false)
      Rails.cache.delete(CACHE_KEY) if force

      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        perform_check
      end
    end

    # Get cached result without making API call
    def cached_result
      Rails.cache.read(CACHE_KEY)
    end

    # Clear cache
    def clear_cache
      Rails.cache.delete(CACHE_KEY)
    end

    private

    def perform_check
      current = current_version
      return no_update_result(current, "Version not available") if current.blank?

      repo = github_repo
      return no_update_result(current, "GitHub repo not configured") if repo.blank?

      latest = fetch_latest_release(repo)
      return no_update_result(current, "No releases found") unless latest

      update = newer_version?(current, latest[:version])

      Result.new(
        update_available: update,
        current_version: current,
        latest_version: latest[:version],
        latest_message: latest[:message],
        latest_date: latest[:date],
        release_url: latest[:url]
      )
    rescue => e
      Rails.logger.error "[UpdateChecker] Error checking for updates: #{e.message}"
      no_update_result(current_version, e.message)
    end

    def no_update_result(current, message = nil)
      Result.new(
        update_available: false,
        current_version: current || "unknown",
        latest_version: nil,
        latest_message: message,
        latest_date: nil,
        release_url: nil
      )
    end

    def current_version
      version_file = Rails.root.join("VERSION")
      return File.read(version_file).strip if File.exist?(version_file)

      nil
    end

    def github_repo
      SettingsService.get(:github_repo)
    end

    def fetch_latest_release(repo)
      response = connection.get("/repos/#{repo}/releases/latest")

      return nil unless response.status == 200

      data = response.body
      tag = data["tag_name"]
      version = tag&.delete_prefix("v")

      {
        version: version,
        message: data["name"] || tag,
        date: parse_date(data["published_at"]),
        url: data["html_url"]
      }
    end

    def parse_date(date_string)
      Time.parse(date_string)
    rescue ArgumentError, TypeError
      nil
    end

    def newer_version?(current, latest)
      return false if current.blank? || latest.blank?

      Gem::Version.new(latest) > Gem::Version.new(current)
    rescue ArgumentError
      # Fall back to string comparison if versions aren't valid semver
      current != latest
    end

    def connection
      @connection ||= Faraday.new(url: "https://api.github.com") do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["Accept"] = "application/vnd.github.v3+json"
        f.headers["User-Agent"] = "Shelfarr"
        f.options.timeout = 10
        f.options.open_timeout = 5
      end
    end
  end
end
