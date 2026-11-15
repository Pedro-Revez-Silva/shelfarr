# frozen_string_literal: true

require "optparse"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: capture_pairing_cases.rb --bundle ABSOLUTE_EXISTING_BUNDLE --out ABSOLUTE_NEW_DIRECTORY"
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
require_relative "lib/pairing_cases"
Migration::Pairing::Cases.new(paths: paths, bundle: options[:bundle]).call
puts "pairing cases written"
