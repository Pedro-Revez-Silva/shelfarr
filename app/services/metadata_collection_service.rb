# frozen_string_literal: true

class MetadataCollectionService
  class Error < StandardError; end

  Item = Data.define(:work_id, :source_work_ids, :metadata_attrs) do
    def title
      metadata_attrs[:title]
    end

    def cover_url
      metadata_attrs[:cover_url]
    end

    def issue_number
      metadata_attrs[:issue_number]
    end

    def release_date
      metadata_attrs[:release_date]
    end

    def series_position
      metadata_attrs[:series_position]
    end
  end

  class << self
    def expand(source:, collection_id:, collection_title: nil, content_kind: "book", limit: nil)
      new(
        source: source,
        collection_id: collection_id,
        collection_title: collection_title,
        content_kind: content_kind,
        limit: limit
      ).expand
    end
  end

  def initialize(source:, collection_id:, collection_title: nil, content_kind: "book", limit: nil)
    @source = source.to_s
    @collection_id = collection_id.to_s
    @collection_title = collection_title
    @content_kind = content_kind.presence || "book"
    @limit = limit
  end

  def expand
    raise Error, "Missing collection source" if source.blank?
    raise Error, "Missing collection identifier" if collection_id.blank?

    case source
    when "comic_vine"
      comic_vine_items
    when "hardcover"
      hardcover_items
    else
      raise Error, "Collection requests are not supported for #{MetadataSources.display_name(source)}"
    end
  rescue HardcoverClient::Error, ComicVineClient::Error => e
    raise Error, "Could not load collection metadata: #{e.message}"
  end

  private

  attr_reader :source, :collection_id, :collection_title, :content_kind, :limit

  def comic_vine_items
    raise Error, "Comic Vine is not configured" unless ComicVineClient.configured?

    ComicVineClient.volume_issues(collection_id, limit: limit, content_kind: comic_content_kind).map do |result|
      work_id = "comic_vine:#{result.resource_key}"
      Item.new(
        work_id: work_id,
        source_work_ids: [ work_id ],
        metadata_attrs: {
          title: result.title,
          author: result.creators,
          cover_url: result.cover_url,
          first_publish_year: result.year,
          description: result.description,
          publisher: result.publisher,
          content_kind: result.content_kind.presence || comic_content_kind,
          issue_number: result.issue_number,
          release_date: result.release_date,
          series: result.series_name,
          series_position: result.issue_number,
          request_scope: "collection",
          collection_source: "comic_vine",
          collection_id: result.collection_id.presence || collection_id,
          collection_title: result.collection_title.presence || collection_title
        }.compact
      )
    end
  end

  def hardcover_items
    HardcoverClient.series_books(collection_id, limit: limit).map do |result|
      work_id = "hardcover:#{result.id}"
      Item.new(
        work_id: work_id,
        source_work_ids: [ work_id ],
        metadata_attrs: {
          title: result.title,
          author: result.author,
          cover_url: result.cover_url,
          first_publish_year: result.release_year,
          description: result.description,
          content_kind: "book",
          series: result.series_name.presence || collection_title,
          series_position: result.series_position,
          request_scope: "collection",
          collection_source: "hardcover",
          collection_id: collection_id,
          collection_title: result.series_name.presence || collection_title
        }.compact
      )
    end
  end

  def comic_content_kind
    %w[comic manga].include?(content_kind.to_s) ? content_kind.to_s : "comic"
  end
end
