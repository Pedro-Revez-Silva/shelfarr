# frozen_string_literal: true

require "optparse"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: capture_http_cases.rb --bundle ABSOLUTE_EXISTING_BUNDLE --out ABSOLUTE_NEW_DIRECTORY"
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

require_relative "lib/http_cases"
Migration::Http::Cases.new(paths: paths, bundle: options[:bundle]).call
puts "http cases written"
