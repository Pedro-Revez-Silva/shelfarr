# frozen_string_literal: true

class API::V1::RequestsController < API::V1::ApplicationController
  before_action -> { require_scope!("requests:read") }, only: [ :index, :show, :search_results ]
  before_action -> { require_scope!("requests:write") }, only: [ :create, :destroy ]
  before_action -> { require_scope!("requests:admin") }, only: [ :retry, :blocklist_and_next ]
  before_action :set_request, only: [ :show, :destroy, :retry, :search_results, :blocklist_and_next ]

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
      metadata_attrs: create_params.slice(
        :title, :author, :cover_url, :year, :first_publish_year,
        :description, :publisher, :content_kind, :issue_number, :release_date,
        :series, :series_position, :request_scope, :collection_source,
        :collection_id, :collection_title
      ),
      notes: create_params[:notes],
      language: create_params[:language],
      source_work_ids: create_params[:source_work_ids],
      origin: {
        created_via: "api",
        external_source: create_params[:external_source].presence || "api",
        external_user_id: create_params[:external_user_id],
        external_chat_id: create_params[:external_chat_id]
      }
    )

    status = if result.queued?
      :accepted
    elsif result.success?
      :created
    else
      :unprocessable_entity
    end
    render json: {
      requests: result.created_requests.map { |request| request_payload(request) },
      queued: result.queued?,
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

  def search_results
    render json: {
      search_results: @request.search_results.includes(:acquisition_provider).best_first.map { |result| search_result_payload(result) }
    }
  end

  def blocklist_and_next
    if params[:search_result_id].present?
      grab_search_result
      return
    end

    case @request.blocklist_and_select_next!(reason: "Blocklisted via API")
    when :no_selected_result
      render json: { errors: [ "No selected result to blocklist" ] }, status: :unprocessable_entity
    when :exhausted
      render json: request_payload(@request.reload)
    else
      render json: request_payload_with_selected_result(@request.reload)
    end
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
      :description,
      :publisher,
      :content_kind,
      :issue_number,
      :release_date,
      :series,
      :series_position,
      :request_scope,
      :collection_source,
      :collection_id,
      :collection_title,
      :notes,
      :language,
      :external_source,
      :external_user_id,
      :external_chat_id,
      source_work_ids: [],
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
        external_source: request.external_source,
        request_scope: request.request_scope,
        collection_source: request.collection_source,
        collection_id: request.collection_id,
        collection_title: request.collection_title
      },
      book: {
        id: request.book_id,
        title: request.book.title,
        author: request.book.author,
        book_type: request.book.book_type,
        book_type_label: request.book.book_type_label,
        content_kind: request.book.content_kind,
        collection_title: request.collection_title,
        work_id: request.book.unified_work_id,
        metadata_source_name: request.book.metadata_source_name,
        metadata_source_url: request.book.metadata_source_url,
        metadata_source_attribution: request.book.metadata_source_attribution
      },
      user: {
        id: request.user_id,
        username: request.user.username
      }
    }
  end

  def request_payload_with_selected_result(request)
    request_payload(request).merge(
      selected_result: request.search_results.selected.first.then { |result| result && search_result_payload(result) }
    )
  end

  def search_result_payload(result)
    {
      id: result.id,
      title: result.title,
      source: result.source,
      indexer: result.indexer,
      seeders: result.seeders,
      leechers: result.leechers,
      size_bytes: result.size_bytes,
      confidence_score: result.confidence_score,
      detected_language: result.detected_language,
      status: result.status,
      downloadable: result.downloadable?,
      blocklisted: result.blocklisted?,
      blocklisted_at: result.blocklisted_at&.iso8601,
      blocklist_reason: result.blocklist_reason
    }
  end

  def grab_search_result
    result = @request.search_results.find(params[:search_result_id])
    @request.select_result!(result)
    render json: request_payload_with_selected_result(@request.reload)
  rescue ActiveRecord::RecordNotFound
    render json: { errors: [ "Search result not found" ] }, status: :not_found
  rescue ArgumentError => e
    render json: { errors: [ e.message ] }, status: :unprocessable_entity
  end
end
