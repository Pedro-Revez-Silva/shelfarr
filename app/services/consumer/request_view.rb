# frozen_string_literal: true

# How a native app sees one of its account's requests. `stage` is the
# client-facing summary; `status` is the server's own value, for diagnostics.
# Nothing here exposes indexers, download clients, paths or other accounts.
class Consumer::RequestView
  READABLE_TYPES = %w[ebook audiobook].freeze
  STAGES = %w[queued searching not_found awaiting_purchase downloading processing available completed failed].freeze

  def self.many(requests)
    downloads = Download.where(request_id: requests.map(&:id), status: [ :queued, :downloading, :paused ])
      .order(:id).group_by(&:request_id)
    requests.map { |request| new(request, active_downloads: downloads[request.id] || []).representation }
  end

  def initialize(request, active_downloads: nil)
    @request = request
    @book = request.book
    @active_downloads = active_downloads || request.downloads.where(status: [ :queued, :downloading, :paused ]).order(:id).to_a
  end

  def representation
    {
      id: @request.id.to_s,
      status: @request.status,
      stage: stage,
      attention_needed: @request.attention_needed,
      title: @book.title,
      author: @book.author,
      book_type: @book.book_type,
      cover_url: safe_cover,
      download_percent: download_percent,
      can_cancel: @request.can_be_cancelled?,
      next_retry_at: @request.next_retry_at&.iso8601,
      publication_id: publication_id,
      created_at: @request.created_at.iso8601,
      updated_at: @request.updated_at.iso8601
    }
  end

  private

  def stage
    case @request.status
    when "pending" then "queued"
    when "completed" then publication_id ? "available" : "completed"
    else @request.status
    end
  end

  def publication_id
    return unless @request.completed? && @book.acquired? && READABLE_TYPES.include?(@book.book_type)

    @book.id.to_s
  end

  def download_percent
    return unless @request.downloading?

    value = @active_downloads.filter_map(&:progress).max
    value&.clamp(0, 100)
  end

  def safe_cover
    Consumer::SafeLink.call(@book.cover_url)
  end
end
