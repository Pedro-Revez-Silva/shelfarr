source "https://rubygems.org"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
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

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

gem "kamal", require: false

gem "thruster", require: false

gem "image_processing", "~> 1.2"

gem "faraday"
# Multipart file upload support for qBittorrent torrent file submissions
gem "faraday-multipart"
gem "oj"
gem "rubyzip", ">= 3.4.0", require: "zip"
# Parse .torrent files to extract info hash
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
  # Pin minitest to a compatible version with Rails 8.1
  gem "minitest", "~> 5.25"
  gem "simplecov", require: false
  gem "mutant", require: false
  gem "mutant-minitest", require: false
end
