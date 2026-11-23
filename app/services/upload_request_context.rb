# frozen_string_literal: true

module UploadRequestContext
  Refusal = Struct.new(:reason, :message, keyword_init: true)

  NOT_OWNER = Refusal.new(reason: :not_owner, message: "You cannot upload files for this request.").freeze
  COMPLETED = Refusal.new(reason: :closed, message: "This request is already completed.").freeze
  CLOSED = Refusal.new(reason: :closed, message: "This request is no longer open for file fulfillment. Retry it before uploading a file.").freeze

  module_function

  def refusal(request, user:)
    return NOT_OWNER unless user.admin? || request.user_id == user.id
    return if request.upload_fulfillable?

    request.completed? ? COMPLETED : CLOSED
  end
end
