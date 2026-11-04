source "https://rubygems.org"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# Loofah CSS tokenizer. 1.0.7 leaves a bad URL open after an escaped backslash.
gem "crass", ">= 1.0.8"
# Rack 3.2.7 and older return an invalid Host from host_with_port.
gem "rack", ">= 3.2.8"
gem "propshaft"
gem "sqlite3", ">= 2.1"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "tailwindcss-rails"

gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

gem "bootsnap", require: false

gem "kamal", require: false
# Kamal's SSH client. 7.3.7 and older leave a later ProxyJump hop unescaped.
gem "net-ssh", "~> 7.3", ">= 7.3.8", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

gem "image_processing", "~> 1.2"

gem "faraday"
gem "faraday-multipart"
# Public and private suffix boundaries for credential-bearing redirects
gem "public_suffix", "~> 7.0"
gem "resolv", "~> 0.3.2"
gem "oj"
gem "rubyzip", ">= 3.4.0", require: "zip"
gem "bencode"
gem "id3tag"
gem "pdf-reader"
gem "rotp"
gem "rqrcode"
gem "omniauth"
gem "omniauth-rails_csrf_protection"
gem "omniauth_openid_connect"

group :development, :test do
  gem "dotenv-rails"
  gem "faker"
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  gem "bundler-audit", require: false

  gem "brakeman", require: false

  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
  gem "lefthook", require: false
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
  gem "webmock"
  gem "vcr"
  gem "minitest", "~> 5.25"
  gem "simplecov", require: false
  gem "mutant", require: false
  gem "mutant-minitest", require: false
end
