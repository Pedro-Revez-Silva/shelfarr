# frozen_string_literal: true

class WebPreview::AccountsController < WebPreview::APIController
  PASSWORD_FIELDS = %i[current_password password password_confirmation].freeze

  def show
    render_account
  end

  def profile
    user = Current.user
    return render_error("invalid_request", :unprocessable_entity) unless params[:name].is_a?(String)
    return render_account if user.update(name: params[:name])

    render_rejection("invalid_profile", user)
  end

  def password
    user = Current.user
    return render_error("invalid_request", :unprocessable_entity) unless PASSWORD_FIELDS.all? { |field| params[field].is_a?(String) }

    unless user.authenticate(params[:current_password])
      user.errors.add(:current_password, "is incorrect")
      return render_rejection("invalid_password", user)
    end
    return render_rejection("invalid_password", user) unless user.update(password: params[:password], password_confirmation: params[:password_confirmation])

    user.sessions.where.not(id: Current.session.id).destroy_all
    render_account
  end

  private

  def render_account
    render json: { account: web_preview_account_id, profile: WebPreview::AccountJson.new(Current.user, routes: self).profile }
  end

  def render_rejection(code, user)
    render json: { account: web_preview_account_id, error: code, errors: user.errors.to_hash }, status: :unprocessable_entity
  end
end
