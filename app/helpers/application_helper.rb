module ApplicationHelper
  # Returns the path for assets in the public folder, respecting RAILS_RELATIVE_URL_ROOT
  # Use this for static assets like /icon.png or /images/no-cover.svg
  def public_asset_path(path)
    # Use request.script_name which is set by Rack::URLMap when app is mounted at a subpath
    base = request.script_name.to_s
    "#{base}/#{path.to_s.delete_prefix('/')}"
  end

  # OmniAuth request path, including RAILS_RELATIVE_URL_ROOT when mounted
  def oidc_auth_path
    OidcPaths.request_path(script_name: request.script_name)
  end
end
