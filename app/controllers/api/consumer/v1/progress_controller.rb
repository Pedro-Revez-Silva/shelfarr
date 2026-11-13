# frozen_string_literal: true

class API::Consumer::V1::ProgressController < API::Consumer::V1::BaseController
  before_action -> { consumer_scope(action_name == "update" ? "progress:write" : "library:read") }

  def show
    progress = Current.user.consumer_progresses.find_by(book: consumer_book)
    render json: { progress: progress&.representation }
  end

  def update
    result = Consumer::ProgressWriter.new(user: Current.user, book: consumer_book).call(Consumer::ProgressWriter.attributes(params))
    render json: { progress: result.representation }
  rescue Consumer::ProgressWriter::Invalid, Consumer::LibraryAssets::Unavailable => error
    render json: { error: "invalid_progress", message: error.message }, status: :unprocessable_entity
  rescue Consumer::ProgressWriter::Conflict => error
    render json: { error: "progress_conflict", progress: error.progress&.representation }, status: :conflict
  end
end
