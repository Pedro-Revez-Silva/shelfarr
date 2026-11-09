# frozen_string_literal: true

class Consumer::ConnectionsController < ApplicationController
  before_action :private_response

  def show
    @user_code = params[:user_code].is_a?(String) ? params[:user_code].first(32) : ""
    @grant = ConsumerDeviceGrant.for_user_code(@user_code) if @user_code.present?
  end

  def create
    return head :bad_request unless %w[allow deny].include?(params[:decision])

    @user_code = params[:user_code].is_a?(String) ? params[:user_code].first(32) : ""
    @grant = ConsumerDeviceGrant.for_user_code(@user_code)
    if @grant&.decide!(actor: Current.user, allow: params[:decision] == "allow")
      @allowed = params[:decision] == "allow"
      render :complete
    elsif @grant&.pending? && !@grant.decidable_by?(Current.user)
      flash.now[:alert] = "This app is connected to a different Shelfarr account. Nothing was changed."
      render :show, status: :forbidden
    else
      flash.now[:alert] = "This connection code has expired or has already been used. Start again in the app."
      render :show, status: :unprocessable_entity
    end
  end

  private

  def private_response
    headers["Cache-Control"] = "private, no-store"
    headers["Referrer-Policy"] = "no-referrer"
  end
end
