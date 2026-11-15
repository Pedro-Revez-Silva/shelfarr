# frozen_string_literal: true

require "optparse"
require_relative "lib/producer_boot"

REPO_ROOT = File.expand_path("../..", __dir__)
MODES = %w[current-schema stable-upgrade].freeze

options = { mode: "current-schema" }
OptionParser.new do |parser|
  parser.banner = "Usage: produce_fixture.rb --out ABSOLUTE_NEW_DIRECTORY [--mode current-schema|stable-upgrade]"
  parser.on("--out PATH") { |value| options[:out] = value }
  parser.on("--mode MODE", MODES) { |value| options[:mode] = value }
end.parse!

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

if options[:mode] == "stable-upgrade"
  require_relative "lib/stable_upgrade_builder"
  begin
    Migration::StableUpgradeBuilder.new(paths: paths, repo_root: REPO_ROOT).call
  rescue Migration::StableUpgrade::Failed => error
    warn "upgrade failed: #{error.message}"
    exit 3
  end
else
  require_relative "lib/fixture_builder"
  Migration::FixtureBuilder.new(paths: paths, repo_root: REPO_ROOT).call
end
puts "fixture bundle written"
