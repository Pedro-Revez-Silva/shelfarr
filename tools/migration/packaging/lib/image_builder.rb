# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require_relative "git_source"
require_relative "../../volume/lib/pins"

module Migration
  module Packaging
    class BuildFailed < StandardError; end

    class ImageBuilder
      Result = Data.define(:role, :commit, :tree, :image, :image_id, :built)

      def initialize(root:, scratch:, log:)
        @root = root
        @scratch = scratch
        @log = log
      end

      def release(pin)
        tree = GitSource.resolve(@root, pin.commit, tree: pin.tree)
        build_rails(pin.role, pin.commit, tree, pin.version_label)
      end

      def candidate
        commit = GitSource.clean_head(@root)
        tree = GitSource.resolve(@root, commit)
        rails = build_rails("candidate-rails", commit, tree, "candidate")
        context = export(commit, "candidate-#{commit[0, 12]}")
        packaged = Volume::Pins.image("candidate", commit)
        docker_build(packaged, context, "tools/migration/packaging/Dockerfile", "RAILS_IMAGE" => rails.image, "GO_IMAGE" => Volume::Pins::GO_IMAGE)
        Result.new(role: "candidate", commit: commit, tree: tree, image: packaged, image_id: image_id(packaged), built: true)
      end

      def build_rails(role, commit, tree, version)
        image = Volume::Pins.image(role, commit)
        context = export(commit, "#{role}-#{commit[0, 12]}")
        docker_build(image, context, "Dockerfile", "APP_VERSION" => version, "RUBY_VERSION" => "3.3.13")
        Result.new(role: role, commit: commit, tree: tree, image: image, image_id: image_id(image), built: true)
      end

      def image_id(image)
        output, status = Open3.capture2("docker", "image", "inspect", "--format", "{{.Id}}", image)
        raise BuildFailed, "image #{image} missing after build" unless status.success?

        output.strip
      end

      def export(commit, name)
        destination = File.join(@scratch, "contexts", name)
        FileUtils.rm_rf(destination)
        GitSource.export(@root, commit, destination)
      end

      def docker_build(image, context, dockerfile, arguments)
        command = [ "docker", "build", "--pull=false", "--tag", image, "--file", File.join(context, dockerfile),
                    "--label", "org.shelfarr.m2.source=#{File.basename(context)}" ]
        arguments.each { |key, value| command.push("--build-arg", "#{key}=#{value}") }
        command << context
        @log.call("build #{image}")
        output, status = Open3.capture2e({ "DOCKER_BUILDKIT" => "1" }, *command)
        File.write(File.join(@scratch, "build-#{image.tr('/:', '__')}.log"), output)
        raise BuildFailed, "build of #{image} failed; see the scratch log" unless status.success?
      end
    end
  end
end
