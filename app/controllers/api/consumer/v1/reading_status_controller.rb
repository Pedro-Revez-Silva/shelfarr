# frozen_string_literal: true

class API::Consumer::V1::ReadingStatusController < API::Consumer::V1::BaseController
  before_action -> { consumer_scope("progress:write") }

  def update
    book = consumer_book
    Consumer::ReadingStatus.set(user: Current.user, book: book, status: params[:status])
    render json: Consumer::Publication.new(book, user: Current.user, routes: self).representation
  rescue Consumer::ReadingStatus::Invalid => error
    render json: { error: "invalid_reading_status", message: error.message }, status: :unprocessable_entity
  end
end
