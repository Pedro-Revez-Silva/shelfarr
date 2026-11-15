# frozen_string_literal: true

module Migration
  module Volume
    Release = Data.define(:role, :commit, :tree, :version_label)

    module Pins
      STABLE = Release.new(role: "stable", commit: "96333c6674a21701f7229c1a51038dc3b117c1a0", tree: "c9a17fcfa4591898ac47a299e8fab09ecd2c15c1", version_label: "v2026.11.05.1")
      BETA = Release.new(role: "beta", commit: "ca3ce810a50053b1279048c7b705c1fae97c0a9a", tree: "6f21bc30ef3a2d2b43614d6fdb3582a6c72733c8", version_label: "beta-predecessor")
      RUBY_IMAGE = "docker.io/library/ruby:3.3.13-slim"
      GO_IMAGE = "docker.io/library/golang:1.27.4"
      BUN_IMAGE = "docker.io/oven/bun:1.4.4"
      WEB_ASSETS_DIRECTORY = "/usr/local/share/shelfarr/web"
      IMAGE_REPOSITORY = "shelfarr-m2"
      PROJECT_PREFIX = "shelfarr-m2"
      ARCHITECTURES = %w[amd64 arm64].freeze
      GO_BINARIES = %w[shelfarr-compat shelfarr-workflows shelfarr-http].freeze

      module_function

      def image(role, commit)
        "#{IMAGE_REPOSITORY}/#{role}:#{commit[0, 12]}"
      end
    end
  end
end
