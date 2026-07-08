# frozen_string_literal: true

require "net/http"
require "json"

class ComicVineClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end

  API_URL = "https://comicvine.gamespot.com/api/"
  USER_AGENT = "Shelfarr/#{Rails.application.config.respond_to?(:app_version) ? Rails.application.config.app_version : 'dev'}"
  MAX_PAGE_SIZE = 100
  ISSUE_FIELD_LIST = %w[
    id name issue_number cover_date date_added description deck image site_detail_url
    volume person_credits
  ].join(",")
  VOLUME_FIELD_LIST = %w[
    id name start_year description deck image site_detail_url publisher count_of_issues
  ].join(",")

  Result = Data.define(
    :id, :resource_type, :resource_key, :title, :description, :cover_url,
    :publisher, :creators, :series_name, :issue_number, :release_date,
    :content_kind, :collection_id, :collection_title, :web_url, :raw_payload
  ) do
    def author
      creators
    end

    def year
      date = release_date.to_s
      date[0, 4].presence&.to_i
    end
  end

  class << self
    def configured?
      SettingsService.comic_vine_configured?
    end

    def search(query, limit: nil, content_kind: nil)
      return [] unless configured?

      response = get_json(
        "/search/",
        query: query,
        resources: "volume,issue",
        limit: limit || SettingsService.get(:comic_vine_search_limit, default: 10)
      )

      Array(response["results"]).filter_map do |payload|
        parse_result(payload, requested_content_kind: content_kind)
      end
    end

    def details(resource_key, content_kind: nil)
      return nil unless configured?

      type, id = parse_resource_key(resource_key)
      path = type == "issue" ? "/issue/4000-#{id}/" : "/volume/4050-#{id}/"
      fields = type == "issue" ? ISSUE_FIELD_LIST : VOLUME_FIELD_LIST
      response = get_json(path, field_list: fields)
      payload = response["results"]
      return nil unless payload.is_a?(Hash)

      parse_result(payload.merge("resource_type" => type), requested_content_kind: content_kind)
    end

    def volume_issues(volume_key, limit: nil, content_kind: nil)
      return [] unless configured?
      return [] if limit.present? && limit.to_i <= 0

      volume_id = volume_id_from_resource_key(volume_key)
      return [] if volume_id.blank?

      remaining = limit&.to_i
      offset = 0
      issues = []

      loop do
        page_size = remaining ? [ remaining, MAX_PAGE_SIZE ].min : MAX_PAGE_SIZE
        response = get_json(
          "/issues/",
          filter: "volume:#{volume_id}",
          sort: "cover_date:asc",
          field_list: ISSUE_FIELD_LIST,
          limit: page_size,
          offset: offset
        )

        page = Array(response["results"]).filter_map do |payload|
          parse_result(payload.merge("resource_type" => "issue"), requested_content_kind: content_kind)
        end
        issues.concat(page)

        break if page.empty?
        remaining -= page.size if remaining
        break if remaining && remaining <= 0

        offset += page_size
        total = response["number_of_total_results"].to_i
        break if total.positive? && offset >= total
      end

      issues
    end

    def test_connection
      configured? && search("Batman", limit: 1).is_a?(Array)
    rescue Error
      false
    end

    private

    def get_json(path, params)
      uri = URI.join(API_URL, path.to_s.delete_prefix("/"))
      uri.query = params.merge(api_key: api_key, format: "json").to_query

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 15, open_timeout: 10) do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT
        http.request(request)
      end

      raise AuthenticationError, "Comic Vine authentication failed" if response.code.to_i == 401
      raise ConnectionError, "Comic Vine returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      status_code = body["status_code"].to_i
      raise AuthenticationError, body["error"] if status_code == 100
      raise Error, body["error"] if status_code != 1

      body
    rescue JSON::ParserError => e
      raise Error, "Invalid Comic Vine response: #{e.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
      raise ConnectionError, e.message
    end

    def parse_result(payload, requested_content_kind:)
      resource_type = payload["resource_type"].to_s
      return unless %w[volume issue].include?(resource_type)

      volume = payload["volume"].is_a?(Hash) ? payload["volume"] : {}
      series_title = payload["name"].presence
      issue_title = [ volume["name"], issue_label(payload), payload["name"] ].compact_blank.join(" - ")
      release_date = payload["cover_date"].presence || payload["date_added"].presence || payload["start_year"].presence

      Result.new(
        id: payload["id"].to_s,
        resource_type: resource_type,
        resource_key: resource_key(resource_type, payload["id"]),
        title: resource_type == "issue" ? issue_title : series_title,
        description: clean_html(payload["description"].presence || payload["deck"]),
        cover_url: payload.dig("image", "super_url") || payload.dig("image", "original_url"),
        publisher: payload.dig("publisher", "name"),
        creators: creator_names(payload),
        series_name: resource_type == "issue" ? volume["name"] : payload["name"],
        issue_number: resource_type == "issue" ? payload["issue_number"].presence : nil,
        release_date: release_date,
        content_kind: content_kind_for(payload, requested_content_kind),
        collection_id: resource_type == "issue" ? resource_key("volume", volume["id"]) : resource_key("volume", payload["id"]),
        collection_title: resource_type == "issue" ? volume["name"] : payload["name"],
        web_url: payload["site_detail_url"],
        raw_payload: payload
      )
    end

    def parse_resource_key(resource_key)
      key = resource_key.to_s.strip.delete_prefix("comic_vine:")
      if key.start_with?("4000-")
        [ "issue", key.delete_prefix("4000-") ]
      elsif key.start_with?("4050-")
        [ "volume", key.delete_prefix("4050-") ]
      else
        [ "volume", key ]
      end
    end

    def volume_id_from_resource_key(resource_key)
      _type, id = parse_resource_key(resource_key)
      id
    end

    def resource_key(resource_type, id)
      return nil if id.blank?

      prefix = resource_type.to_s == "issue" ? "4000" : "4050"
      "#{prefix}-#{id}"
    end

    def issue_label(payload)
      issue_number = payload["issue_number"].presence
      issue_number ? "##{issue_number}" : nil
    end

    def creator_names(payload)
      Array(payload["person_credits"]).filter_map { |person| person["name"] }.first(4).join(", ").presence
    end

    def content_kind_for(payload, requested_content_kind)
      requested = requested_content_kind.to_s
      return requested if %w[comic manga].include?(requested)

      searchable = [ payload["name"], payload["description"], payload["deck"], payload.dig("publisher", "name") ].join(" ")
      searchable.match?(/\bmanga\b/i) ? "manga" : "comic"
    end

    def clean_html(value)
      ActionView::Base.full_sanitizer.sanitize(value.to_s).squish.presence
    end

    def api_key
      SettingsService.get(:comic_vine_api_key).to_s.strip
    end
  end
end
