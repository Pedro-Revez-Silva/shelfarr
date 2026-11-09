# frozen_string_literal: true

# filter_parameters hides route params but not Rails' "Started GET /path".
# Keep the routing path intact and redact the separate logging representation.
module KoboLogFilter
  def filtered_path
    logged = super
    logged = logged.split("?", 2).first if kobo_reader_request?
    logged.gsub(%r{(/kobo/)[^/?]+}, '\1[FILTERED]')
  end

  # Reader requests, including Store requests relayed for coexistence, carry
  # account and device identifiers under names no filter list anticipates.
  # Log only routing information for them.
  def filtered_parameters
    return super unless kobo_reader_request?

    path_parameters.slice(:controller, :action, :format).stringify_keys
  end

  private

  def kobo_reader_request?
    path_info.to_s.match?(%r{(?:\A|/)kobo/[^/]+(?:/|\z)})
  end
end

ActionDispatch::Request.prepend(KoboLogFilter)
