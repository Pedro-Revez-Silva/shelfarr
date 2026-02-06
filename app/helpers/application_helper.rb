module ApplicationHelper
  # Returns the path for assets in the public folder, respecting RAILS_RELATIVE_URL_ROOT
  # Use this for static assets like /icon.png or /images/no-cover.svg
  def public_asset_path(path)
    # Use request.script_name which is set by Rack::URLMap when app is mounted at a subpath
    base = request.script_name.to_s
    "#{base}/#{path.to_s.delete_prefix('/')}"
  end
end
