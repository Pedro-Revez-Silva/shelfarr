ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

# Credential *_FILE values have to be in ENV before Rails reads them.
require_relative "../lib/shelfarr/secret_env_files"

begin
  Shelfarr::SecretEnvFiles.load!
rescue Shelfarr::SecretEnvFiles::Error => error
  abort error.message
end

require "bundler/setup"
require "bootsnap/setup"
