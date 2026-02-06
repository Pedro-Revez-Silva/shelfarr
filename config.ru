# This file is used by Rack-based servers to start the application.

require_relative "config/environment"

# Support running the app at a sub-path via RAILS_RELATIVE_URL_ROOT
# This properly sets SCRIPT_NAME so route helpers include the prefix
relative_url_root = ENV.fetch("RAILS_RELATIVE_URL_ROOT", "/")

if relative_url_root != "/" && relative_url_root.present?
  map relative_url_root do
    run Rails.application
  end
else
  run Rails.application
end

Rails.application.load_server
