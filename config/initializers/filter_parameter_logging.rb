Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :nzb_url, :download_url, :response_url, :authorization_code, :account, :session_id, :userkey,
  # OAuth callback and device sign-in values. Matched exactly so unrelated
  # keys that merely contain "code" (an ISBN code, a language code) still log.
  /\A(?:code|device_code|user_code|code_verifier)\z/i
]
