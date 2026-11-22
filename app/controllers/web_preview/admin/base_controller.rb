# frozen_string_literal: true

class WebPreview::Admin::BaseController < WebPreview::APIController
  before_action :require_admin

  private

  def require_admin
    render_error("not_found", :not_found) unless Current.user.admin?
  end

  def outcome_json(outcome)
    { tone: outcome.success? ? "success" : "error", message: WebPreview::SecretRedaction.call(outcome.message) }
  end

  def success(message)
    { tone: "success", message: message }
  end

  def failure(message)
    { tone: "error", message: WebPreview::SecretRedaction.call(message) }
  end
end
