# frozen_string_literal: true

# Public page for installing the Shelfarr Android app from this server. It
# serves the server's cached build and then hands this server's public
# address to the freshly installed app through a shelfarr://connect link.
# Signing in still happens in the browser afterwards, as usual.
class AndroidAppsController < ApplicationController
  allow_unauthenticated_access

  def show
    headers["Cache-Control"] = "no-store"
    resume_session
    @channel = params[:channel].presence || "release"
    return head(:not_found) unless @channel.is_a?(String) && AndroidUpdates::Configuration::CHANNELS.include?(@channel)

    @configuration = AndroidUpdates::Configuration.current
    @offered = @configuration.enabled?(@channel)
    store = AndroidUpdates::Store.new
    @release = store.ready_release(@channel) if @offered
    @last_problem = store.status.dig("channels", @channel, "error") if @offered && Current.user&.admin?
    @server_address = AndroidServerAddress.new(request)
    response.status = :not_found unless @offered
  end
end
