# frozen_string_literal: true

class API::Consumer::V1::ProgressController < API::Consumer::V1::BaseController
  before_action -> { consumer_scope(action_name == "update" ? "progress:write" : "library:read") }

  def show
    progress = Current.user.consumer_progresses.find_by(book: consumer_book)
    render json: { progress: progress&.representation }
  end

  def update
    values = params.permit(:asset_id, :expected_version, :client_mutation_id, :position_seconds, locator: {}).to_h
    result = Consumer::ProgressWriter.new(user: Current.user, book: consumer_book).call(values)
    render json: { progress: result.representation }
  rescue Consumer::ProgressWriter::Invalid, Consumer::LibraryAssets::Unavailable => error
    render json: { error: "invalid_progress", message: error.message }, status: :unprocessable_entity
  rescue Consumer::ProgressWriter::Conflict => error
    render json: { error: "progress_conflict", progress: error.progress&.representation }, status: :conflict
  end
end
