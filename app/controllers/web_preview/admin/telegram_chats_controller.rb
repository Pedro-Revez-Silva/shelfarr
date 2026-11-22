# frozen_string_literal: true

class WebPreview::Admin::TelegramChatsController < WebPreview::Admin::BaseController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/
  CODE = /\A\d{6}\z/

  def index
    render json: { account: web_preview_account_id, chats: chats }
  end

  def create
    code = params[:code].to_s.strip
    authorization = TelegramChatAuthorization.approve_code!(code, approved_by: Current.user) if code.match?(CODE)
    outcome = authorization ? success("Telegram group authorized: #{label(authorization)}") : failure("Telegram group code is invalid or expired.")
    render json: { account: web_preview_account_id, outcome: outcome, chats: chats }
  end

  def pause
    authorization = find_authorization
    authorization.pause!
    render json: { account: web_preview_account_id, outcome: success("Telegram group paused: #{label(authorization)}"), chats: chats }
  end

  def resume
    authorization = find_authorization
    authorization.resume!
    render json: { account: web_preview_account_id, outcome: success("Telegram group resumed: #{label(authorization)}"), chats: chats }
  end

  def destroy
    authorization = find_authorization
    name = label(authorization)
    authorization.destroy!
    render json: { account: web_preview_account_id, outcome: success("Telegram group removed: #{name}"), chats: chats }
  end

  private

  def find_authorization
    id = params[:id].to_s
    raise ActiveRecord::RecordNotFound unless id.match?(IDENTIFIER)

    TelegramChatAuthorization.find(id)
  end

  def label(authorization)
    authorization.chat_title.presence || authorization.chat_id.to_s
  end

  def chats
    TelegramChatAuthorization.order(approved_at: :desc, updated_at: :desc).map do |authorization|
      { id: authorization.id.to_s, label: label(authorization), chat_id: authorization.chat_id.to_s, state: state(authorization) }
    end
  end

  def state(authorization)
    return "paused" if authorization.paused?
    return "authorized" if authorization.approved?
    return "expired" if authorization.expired?

    "pending"
  end
end
