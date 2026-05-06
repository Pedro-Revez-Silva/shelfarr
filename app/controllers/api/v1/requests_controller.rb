# frozen_string_literal: true

class API::V1::RequestsController < API::V1::ApplicationController
  before_action :set_request, only: :show

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
      language: create_params[:language]
    )

    status = result.success? ? :created : :unprocessable_entity
    render json: {
      requests: result.created_requests.map { |request| request_payload(request) },
      warnings: result.warnings,
      errors: result.errors
    }, status: status
  end

  private

  def set_request
    @request = Request.includes(:book, :user).find(params[:id])
  end

  def find_user
    if create_params[:user_id].present?
      User.active.find_by(id: create_params[:user_id])
    elsif create_params[:username].present?
      User.active.find_by(username: create_params[:username].to_s.strip.downcase)
    end
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
        attention_needed: request.attention_needed
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
