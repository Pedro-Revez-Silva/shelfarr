# frozen_string_literal: true

require "optparse"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: capture_browser_cases.rb --bundle ABSOLUTE_EXISTING_BUNDLE --out ABSOLUTE_NEW_DIRECTORY"
  parser.on("--bundle PATH") { |value| options[:bundle] = value }
  parser.on("--out PATH") { |value| options[:out] = value }
end.parse!

abort "refused: --bundle is required" unless options[:bundle]

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

require_relative "../http/lib/http_cases"
require_relative "lib/browser_cases"
Migration::Browser::Cases.new(paths: paths, bundle: options[:bundle]).call
puts "browser cases written"
