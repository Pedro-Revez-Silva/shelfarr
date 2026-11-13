module ApplicationHelper
  def public_asset_path(path)
    # Use request.script_name which is set by Rack::URLMap when app is mounted at a subpath
    base = request.script_name.to_s
    "#{base}/#{path.to_s.delete_prefix('/')}"
  end

  def oidc_auth_path
    "#{request.script_name}/auth/oidc"
  end

  # The public Android install page for this server, if it offers a build.
  def android_app_page_path
    channels = AndroidUpdates::Configuration.current.channels
    return if channels.empty?

    channels.include?("release") ? android_app_path : android_app_path(channel: channels.first)
  end
end
