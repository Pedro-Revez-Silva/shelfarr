# frozen_string_literal: true

require_relative "fixture_isolation"

module Migration
  module ProducerBoot
    module_function

    def call(out:, repo_root:)
      paths = FixtureIsolation.prepare!(out: out, repo_root: repo_root)

      require File.join(repo_root, "config", "boot")
      require "rails"
      require "dotenv"
      require "dotenv/rails"
      Dotenv::Rails.files = [ File.join(paths.tmp, ".env") ]

      require File.join(repo_root, "config", "application")
      Rails.application.config.paths.add("log", with: paths.log)
      FixtureIsolation.redirect_credentials(Rails.application.config, paths)
      FixtureIsolation.verify_credentials!(Rails.application.config, paths)

      Rails.application.initialize!
      FixtureIsolation.verify_databases!(ActiveRecord::Base.configurations, paths)
      paths
    end
  end
end
