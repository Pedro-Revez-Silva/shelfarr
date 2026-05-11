# frozen_string_literal: true

class API::V1::RequestsController < API::V1::ApplicationController
  before_action -> { require_scope!("requests:read") }, only: [ :index, :show ]
  before_action -> { require_scope!("requests:write") }, only: [ :create, :destroy ]
  before_action -> { require_scope!("requests:admin") }, only: :retry
  before_action :set_request, only: [ :show, :destroy, :retry ]

  def index
    requests = request_scope.includes(:book, :user).order(created_at: :desc)
    requests = requests.where(status: params[:status]) if params[:status].present?
    requests = requests.where(created_via: params[:created_via]) if params[:created_via].present?
    requests = requests.limit(index_limit)

    render json: { requests: requests.map { |request| request_payload(request) } }
  end

  def show
    render json: request_payload(@request)
  end

  def create
    user = find_user
    unless user
      render json: { errors: [ "User not found" ] }, status: :not_found
      return
    end

    result = RequestCreationService.call(
      user: user,
      work_id: create_params[:work_id],
      book_types: create_params[:book_types].presence || [ create_params[:book_type] ].compact,
      metadata_attrs: create_params.slice(:title, :author, :cover_url, :year, :first_publish_year),
      notes: create_params[:notes],
      language: create_params[:language],
      origin: {
        created_via: "api",
        external_source: create_params[:external_source].presence || "api",
        external_user_id: create_params[:external_user_id],
        external_chat_id: create_params[:external_chat_id]
      }
    )

    status = result.success? ? :created : :unprocessable_entity
    render json: {
      requests: result.created_requests.map { |request| request_payload(request) },
      warnings: result.warnings,
      errors: result.errors
    }, status: status
  end

  def destroy
    unless @request.can_be_cancelled?
      render json: { errors: [ "Cannot cancel request in #{@request.status} status" ] }, status: :unprocessable_entity
      return
    end

    @request.cancel!
    render json: request_payload(@request)
  end

  def retry
    unless @request.can_retry?
      render json: { errors: [ "Request cannot be retried" ] }, status: :unprocessable_entity
      return
    end

    @request.retry_now!
    render json: request_payload(@request.reload)
  end

  private

  def set_request
    @request = request_scope.includes(:book, :user).find(params[:id])
  end

  def find_user
    requested_user = if create_params[:user_id].present?
      User.active.find_by(id: create_params[:user_id])
    elsif create_params[:username].present?
      User.active.find_by(username: create_params[:username].to_s.strip.downcase)
    elsif Current.api_user
      Current.api_user
    end

    return requested_user if Current.api_admin?
    return requested_user if requested_user && requested_user == Current.api_user

    nil
  end

  def request_scope
    return Request.all if Current.api_admin?
    return Request.for_user(Current.api_user) if Current.api_user

    Request.none
  end

  def index_limit
    (params[:limit].presence || 50).to_i.clamp(1, 100)
  end

  def create_params
    @create_params ||= params.permit(
      :user_id,
      :username,
      :work_id,
      :book_type,
      :title,
      :author,
      :cover_url,
      :year,
      :first_publish_year,
      :notes,
      :language,
      :external_source,
      :external_user_id,
      :external_chat_id,
      book_types: []
    )
  end

  def request_payload(request)
    {
      id: request.id,
      status: request.status,
      attention_needed: request.attention_needed,
      issue_description: request.issue_description,
      created_at: request.created_at.iso8601,
      updated_at: request.updated_at.iso8601,
      request: {
        id: request.id,
        status: request.status,
        attention_needed: request.attention_needed,
        created_via: request.created_via,
        external_source: request.external_source
      },
      book: {
        id: request.book_id,
        title: request.book.title,
        author: request.book.author,
        book_type: request.book.book_type,
        work_id: request.book.unified_work_id
      },
      user: {
        id: request.user_id,
        username: request.user.username
      }
    }
  end
end
