# frozen_string_literal: true

# Exercise the shipped hooks in both Puma cluster boot modes.
config_path = File.expand_path("../../config/puma.rb", __dir__)
instance_eval(File.read(config_path), config_path)
clear_binds!
bind "tcp://127.0.0.1:#{ENV.fetch('PORT')}"
workers 2
preload_app! if ENV["SQIP_MODE"] == "cluster_preload"
# Puma defaults to preloading; explicitly disable it for the other cluster probe.
preload_app!(false) if ENV["SQIP_MODE"] == "cluster"
before_worker_boot do
  File.open(ENV.fetch("SQIP_WORKER_LOG"), "a") { |file| file.puts(Process.pid) }
end
