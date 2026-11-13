# frozen_string_literal: true

class UpdateCheckerService
  class Error < StandardError; end

  Result = Data.define(:update_available, :current_version, :latest_version, :latest_message, :latest_date, :release_url) do
    def update_available?
      update_available
    end
  end

  CACHE_KEY = "shelfarr:update_check"
  CACHE_TTL = 1.hour
  RELEASE_PAGE_SIZE = 100
  RELEASE_PAGE_LIMIT = 10

  class << self
    def check(force: false)
      version = current_version
      cache_key = cache_key_for(version)

      Rails.cache.delete(cache_key) if force

      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        perform_check
      end
    end

    def cached_result
      Rails.cache.read(cache_key_for(current_version))
    end

    def clear_cache
      Rails.cache.delete(cache_key_for(current_version))
      Rails.cache.delete(CACHE_KEY)
    end

    private

    def cache_key_for(version)
      suffix = version.presence || "unknown"
      "#{CACHE_KEY}:#{release_channel.name}:#{suffix}"
    end

    def release_channel
      Shelfarr::ReleaseChannel.current
    end

    def perform_check
      current = current_version
      return no_update_result(current, "Version not available") if current.blank?

      repo = github_repo
      return no_update_result(current, "GitHub repo not configured") if repo.blank?

      latest = release_channel.beta? ? fetch_newest_published_release(repo) : fetch_latest_release(repo)
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
      return nil if data["prerelease"] || Shelfarr::ReleaseChannel.beta_version?(release_version(data))

      release_details(data)
    end

    def fetch_newest_published_release(repo)
      (1..RELEASE_PAGE_LIMIT).each do |page|
        releases = fetch_release_page(repo, page)
        return nil if releases.nil?

        candidates = releases.select { |data| published_server_release?(data) }
        return release_details(candidates.max_by { |data| Gem::Version.new(release_version(data)) }) if candidates.any?
        return nil if releases.size < RELEASE_PAGE_SIZE
      end
      nil
    end

    def fetch_release_page(repo, page)
      response = connection.get("/repos/#{repo}/releases", per_page: RELEASE_PAGE_SIZE, page: page)
      response.body if response.status == 200 && response.body.is_a?(Array)
    end

    def published_server_release?(data)
      data.is_a?(Hash) && !data["draft"] && Shelfarr::ReleaseChannel.published_version?(release_version(data))
    end

    def release_version(data)
      data["tag_name"].to_s.delete_prefix("v")
    end

    def release_details(data)
      {
        version: release_version(data),
        message: data["name"] || data["tag_name"],
        date: parse_date(data["published_at"]),
        url: data["html_url"]
      }
    end

    def parse_date(date_string)
      Time.parse(date_string)
    rescue ArgumentError, TypeError => error
      RemoteResult::Failed.new(error)
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
