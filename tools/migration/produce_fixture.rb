# frozen_string_literal: true

require "optparse"
require_relative "lib/fixture_isolation"

REPO_ROOT = File.expand_path("../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: produce_fixture.rb --out ABSOLUTE_NEW_DIRECTORY"
  parser.on("--out PATH") { |value| options[:out] = value }
end.parse!

begin
  paths = Migration::FixtureIsolation.prepare!(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

require File.join(REPO_ROOT, "config", "application")
Rails.application.config.paths.add("log", with: paths.log)
Rails.application.initialize!

begin
  Migration::FixtureIsolation.verify_databases!(ActiveRecord::Base.configurations, paths)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

require_relative "lib/fixture_builder"
Migration::FixtureBuilder.new(paths: paths, repo_root: REPO_ROOT).call
puts "fixture bundle written"
