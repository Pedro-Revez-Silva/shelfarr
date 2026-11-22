# frozen_string_literal: true

module WebPreview
  module SessionCapabilities
    module_function

    def for(user)
      {
        administrator: user.admin?,
        can_upload: UploadPolicy.new(user, Upload).new?,
        single_sign_on: SettingsService.oidc_configured?,
        hardcover_personal_access: HardcoverIntegration.personal_tokens_allowed?
      }
    end
  end
end
