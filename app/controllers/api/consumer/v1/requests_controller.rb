# frozen_string_literal: true

# A native app's own requests. Creation goes through RequestCreationService, so
# duplicate checks, queueing, notifications and search policy are the same as
# for the web and /api/v1. These endpoints never act for another account, even
# when the approving user is an admin.
class API::Consumer::V1::RequestsController < API::Consumer::V1::BaseController
  before_action -> { consumer_scope("requests:read") }, only: [ :index, :show ]
  before_action -> { consumer_scope("requests:write") }, only: [ :create, :destroy ]

  WORK_ID = /\A[a-z_]{2,32}:[^\s]{1,160}\z/
  TEXT_LIMIT = 500

  def index
    limit = params[:limit].to_s.match?(/\A\d{1,3}\z/) ? params[:limit].to_i.clamp(1, 50) : 30
    requests = own_requests.includes(:book).order(updated_at: :desc, id: :desc).limit(limit).to_a
    render json: { items: Consumer::RequestView.many(requests) }
  end

  def show
    render json: { request: Consumer::RequestView.new(own_request).representation }
  end

  def create
    input = create_input
    return render json: { error: "invalid_request" }, status: :unprocessable_entity unless input

    # A double tap arrives as two concurrent requests. Shelfarr runs one Puma
    # process, so a per-account lock makes the second one see the first one's
    # request; the network-bound metadata lookup must not hold SQLite's lock.
    self.class.creation_lock(Current.user.id).synchronize do
      next if render_existing(input)

      result = RequestCreationService.call(
        user: Current.user,
        work_id: input[:work_id],
        book_types: [ input[:book_type] ],
        source_work_ids: input[:source_work_ids],
        metadata_attrs: input.slice(:title, :author, :cover_url, :year).merge(content_kind: ContentKinds::BOOK),
        language: input[:language],
        origin: { created_via: "api", external_source: "consumer_app" }
      )
      request = result.created_requests.first
      if request
        render json: { request: Consumer::RequestView.new(request.reload).representation, warnings: result.warnings }, status: :created
      elsif !render_existing(input)
        render json: { error: "request_rejected", message: result.errors.first.to_s.first(300) }, status: :unprocessable_entity
      end
    end
  end

  CREATION_LOCKS = Concurrent::Map.new

  def self.creation_lock(user_id)
    CREATION_LOCKS.compute_if_absent(user_id) { Mutex.new }
  end

  def destroy
    request = own_request
    unless request.can_be_cancelled?
      return render json: { error: "cannot_cancel", message: cancel_message(request) }, status: :unprocessable_entity
    end

    request.cancel!
    render json: { request: Consumer::RequestView.new(request.reload).representation }
  rescue Request::CancellationBlockedError => error
    render json: { error: "cannot_cancel", message: error.message.first(300) }, status: :unprocessable_entity
  end

  private

  def own_requests
    Request.for_user(Current.user)
  end

  def own_request
    id = params[:id]
    raise ActiveRecord::RecordNotFound unless id.is_a?(String) && id.match?(/\A[1-9]\d{0,18}\z/)

    own_requests.includes(:book).find(id)
  end

  # A repeated tap, or a title already on its way or on the shelf, is answered
  # with what already exists rather than a second request. Returns whether it
  # rendered.
  def render_existing(input)
    check = DuplicateDetectionService.check(work_id: input[:work_id], source_work_ids: input[:source_work_ids], book_type: input[:book_type])
    return false unless check.block?

    book = check.existing_book
    if book&.acquired?
      render json: { error: "already_in_library", message: check.message,
        publication_id: Consumer::RequestView::READABLE_TYPES.include?(book.book_type) ? book.id.to_s : nil }, status: :conflict
    elsif check.existing_request&.user_id == Current.user.id
      render json: { request: Consumer::RequestView.new(check.existing_request).representation, existing: true }
    else
      render json: { error: "already_requested",
        message: "Someone on this server has already requested this #{input[:book_type]}. It will appear in the library when it arrives." }, status: :conflict
    end
    true
  end

  def create_input
    work_id = params[:work_id]
    book_type = params[:book_type]
    title = params[:title]
    return unless work_id.is_a?(String) && work_id.match?(WORK_ID)
    return unless Consumer::RequestView::READABLE_TYPES.include?(book_type)
    return unless title.is_a?(String) && title.strip.present? && title.length <= TEXT_LIMIT

    sources = params[:source_work_ids]
    sources = [] if sources.nil?
    return unless sources.is_a?(Array) && sources.size <= 20 && sources.all? { |id| id.is_a?(String) && id.match?(WORK_ID) }

    author = optional_text(:author)
    cover_url = optional_text(:cover_url)
    language = optional_text(:language, limit: 16)
    year = params[:year]
    return if [ author, cover_url, language ].include?(:invalid)
    return unless year.nil? || (year.is_a?(Integer) && year.between?(1, 3000))

    { work_id: work_id, book_type: book_type, title: title.strip, author: author, cover_url: https_url(cover_url),
      year: year, language: language, source_work_ids: sources }.compact
  end

  def optional_text(key, limit: TEXT_LIMIT)
    value = params[key]
    return nil if value.nil?
    return :invalid unless value.is_a?(String) && value.length <= limit

    value.strip.presence
  end

  def https_url(value)
    Consumer::SafeLink.call(value)
  end

  def cancel_message(request)
    return request.upload_cancellation_blocked_message if request.upload_cancellation_blocked?
    return "This request has already finished." if request.completed?

    "This request is being finished on the server and can't be cancelled now."
  end
end
