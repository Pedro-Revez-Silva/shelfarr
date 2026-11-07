# frozen_string_literal: true

# filter_parameters hides route params but not Rails' "Started GET /path".
# Keep the routing path intact and redact the separate logging representation.
module KoboLogFilter
  def filtered_path
    super.gsub(%r{(/kobo/)[^/?]+}, '\1[FILTERED]')
  end
end

ActionDispatch::Request.prepend(KoboLogFilter)
