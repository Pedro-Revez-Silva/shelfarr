# frozen_string_literal: true

# Start Solid Queue from the Rails server process when SOLID_QUEUE_IN_PUMA is
# set. This runs during `rails server` boot, before Puma becomes multi-threaded,
# and does not depend on the upstream plugin's after_booted fork.
Rails.application.config.after_initialize do
  next unless Shelfarr::SolidQueueInPuma.enabled?

  Shelfarr::SolidQueueInPuma.start!
end
