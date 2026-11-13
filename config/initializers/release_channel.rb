# frozen_string_literal: true

Rails.application.config.after_initialize do
  Shelfarr::ReleaseChannel.current
end
