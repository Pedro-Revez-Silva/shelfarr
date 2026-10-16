module ApplicationHelper
  def public_asset_path(path)
    # Use request.script_name which is set by Rack::URLMap when app is mounted at a subpath
    base = request.script_name.to_s
    "#{base}/#{path.to_s.delete_prefix('/')}"
  end

  def oidc_auth_path
    "#{request.script_name}/auth/oidc"
  end
end
