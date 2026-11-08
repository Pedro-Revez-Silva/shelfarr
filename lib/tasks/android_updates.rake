# frozen_string_literal: true

namespace :android_updates do
  desc "Fetch and verify the newest compatible Shelfarr Android builds now"
  task refresh: :environment do
    outcome = AndroidUpdates::Refresher.new.call(force: true)
    case outcome.status
    when :busy then puts "Another process is refreshing Android builds; try again when it finishes."
    when :ok
      outcome.channels.each do |channel, result|
        detail = result[:error] ? "kept the previous build (#{result[:error]})" : result[:result]
        puts "#{channel}: #{detail}"
      end
    end
    puts AndroidUpdates::StatusReport.new.lines
    exit 1 unless outcome.ok?
  end

  desc "Show which Shelfarr Android builds this server offers"
  task status: :environment do
    puts AndroidUpdates::StatusReport.new.lines
  end

  desc "Forget a channel's cached build, e.g. android_updates:forget[development]"
  task :forget, [ :channel ] => :environment do |_task, args|
    channel = args[:channel].to_s
    abort "Name a channel: #{AndroidUpdates::Configuration::CHANNELS.join(' or ')}" unless AndroidUpdates::Configuration::CHANNELS.include?(channel)

    store = AndroidUpdates::Store.new
    abort "Another process is refreshing Android builds; try again when it finishes." if store.with_refresh_lock { store.forget!(channel) } == :busy

    puts "Forgot the cached #{channel} build. The next refresh caches the catalog's newest compatible build."
  end
end
