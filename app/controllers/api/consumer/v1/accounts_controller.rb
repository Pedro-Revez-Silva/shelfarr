# frozen_string_literal: true

class API::Consumer::V1::AccountsController < API::Consumer::V1::BaseController
  def show
    consumer_scope("library:read")
    return if performed?

    render json: { id: Current.user.id.to_s, name: Current.user.name, username: Current.user.username,
      scopes: Current.api_token.scope_list.select { |scope| Current.api_token.has_scope?(scope) } }
  end

  def revoke
    Current.api_token.revoke!
    head :no_content
  end
end
