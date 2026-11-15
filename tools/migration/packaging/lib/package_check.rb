# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require_relative "elf"
require_relative "git_source"
require_relative "../../volume/lib/command"
require_relative "../../volume/lib/docker"
require_relative "../../volume/lib/pins"

module Migration
  module Packaging
    class PackageCheck
      Finding = Data.define(:check, :architecture, :mode, :passed, :detail)

      NATIVE = "native-execution"
      EMULATED = "emulated-execution"
      CROSS = "cross-build-inspection"
      HOST_ARCHITECTURES = { "x86_64" => "amd64", "aarch64" => "arm64" }.freeze
      TOOLS = [ %w[ffmpeg -version], %w[ffprobe -version], %w[ruby --version], %w[sqlite3 --version], %w[gosu --version], %w[curl --version] ].freeze
      SYNTHETIC_ENCODE = "ffmpeg -v error -f lavfi -i sine=frequency=440:duration=1 -c:a aac -y /tmp/m2.m4a && ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/m2.m4a"

      attr_reader :findings

      def initialize(root:, scratch:, candidate_image:, commit:)
        @root = root
        @scratch = scratch
        @candidate_image = candidate_image
        @commit = commit
        @findings = []
      end

      def host_architecture
        HOST_ARCHITECTURES.fetch(Volume::Command.run!("uname", "-m").strip)
      end

      def run
        binaries = cross_build_binaries
        inspect_binaries(binaries)
        native = host_architecture
        check_image(@candidate_image, native, NATIVE)
        compare_entrypoint
        compare_container_build_with_host_build(binaries.fetch(native))
        (Volume::Pins::ARCHITECTURES - [ native ]).each { |architecture| check_foreign(architecture, binaries.fetch(architecture)) }
        findings
      end

      private

      def record(check, architecture, mode, passed, detail)
        @findings << Finding.new(check: check, architecture: architecture, mode: mode, passed: passed, detail: detail)
      end

      def go_build(architecture, output)
        environment = { "CGO_ENABLED" => "0", "GOOS" => "linux", "GOARCH" => architecture, "GOTOOLCHAIN" => "auto", "GOFLAGS" => "-mod=readonly" }
        Volume::Pins::GO_BINARIES.to_h do |binary|
          path = File.join(output, binary)
          result = Volume::Command.capture("go", "build", "-trimpath", "-buildvcs=false", "-ldflags=-s -w", "-o", path, "./cmd/#{binary}", environment: environment, timeout: 900)
          raise Volume::CommandFailed, "go build #{binary} #{architecture} failed" unless result.success?

          [ binary, path ]
        end
      end

      def cross_build_binaries
        Volume::Pins::ARCHITECTURES.to_h do |architecture|
          directories = [ "a", "b" ].map { |name| File.join(@scratch, "go-#{architecture}-#{name}").tap { |directory| FileUtils.mkdir_p(directory) } }
          first, second = directories.map do |directory|
            Dir.chdir(File.join(@root, "apps/server")) { go_build(architecture, directory) }
          end
          reproducible = first.all? { |binary, path| Digest::SHA256.file(path) == Digest::SHA256.file(second.fetch(binary)) }
          record("go-binaries-reproducible", architecture, CROSS, reproducible, first.transform_values { |path| Digest::SHA256.file(path).hexdigest[0, 16] }.to_s)
          [ architecture, first ]
        end
      end

      def inspect_binaries(binaries)
        binaries.each do |architecture, files|
          files.each do |name, path|
            description = Elf.describe(path)
            passed = description.architecture == architecture && description.bits == 64 && description.little_endian && description.static
            record("elf-#{name}", architecture, CROSS, passed, "machine=#{description.architecture} bits=#{description.bits} static=#{description.static}")
          end
        end
      end

      def container(image, platform, script, timeout: 600)
        Volume::Command.capture("docker", "run", "--rm", "--network", "none", "--platform", "linux/#{platform}", "--entrypoint", "sh", image, "-c", script, timeout: timeout)
      end

      def check_image(image, architecture, mode)
        reported = container(image, architecture, "uname -m").output.strip
        record("container-architecture", architecture, mode, HOST_ARCHITECTURES.fetch(reported, reported) == architecture, "uname -m=#{reported}")
        TOOLS.each do |tool|
          result = container(image, architecture, tool.join(" "))
          record("runtime-#{tool.first}", architecture, mode, result.success?, result.output.lines.first.to_s.strip[0, 80])
        end
        usage = container(image, architecture, "/usr/local/bin/shelfarr-compat 2>&1; echo exit=$?")
        record("shelfarr-compat-usage", architecture, mode, usage.output.include?("usage: shelfarr-compat compat-check") && usage.output.include?("exit=2"), usage.output.lines.last.to_s.strip)
        workflows = container(image, architecture, "/usr/local/bin/shelfarr-workflows status --workdir /nonexistent 2>&1; echo exit=$?")
        record("shelfarr-workflows-refuses-without-a-workdir", architecture, mode, workflows.output.include?("exit=5"), workflows.output.lines.last.to_s.strip)
        http = container(image, architecture, "/usr/local/bin/shelfarr-http 2>&1")
        disabled = http.status.exitstatus == 2 && http.output == "refused: this runtime is experimental and default-off; pass -experimental\n"
        record("shelfarr-http-refuses-without-opt-in", architecture, mode, disabled, "exit=#{http.status.exitstatus}")
        check_web_assets(image, architecture, mode)
        encoded = container(image, architecture, SYNTHETIC_ENCODE)
        record("ffmpeg-synthetic-aac-encode", architecture, mode, encoded.success? && encoded.output.strip.to_f.between?(0.9, 1.2), "duration=#{encoded.output.strip[0, 12]}")
        vips = container(image, architecture, "ldconfig -p | grep -c 'libvips.so'")
        record("libvips-installed", architecture, mode, vips.success? && vips.output.strip.to_i.positive?, "ldconfig entries=#{vips.output.strip[0, 6]}")
        jemalloc = container(image, architecture, "ls /usr/local/lib/libjemalloc.so")
        record("jemalloc-preload-target", architecture, mode, jemalloc.success?, jemalloc.output.strip)
      end

      def check_web_assets(image, architecture, mode)
        directory = Volume::Pins::WEB_ASSETS_DIRECTORY
        listed = JSON.parse(container(image, architecture, "cat #{directory}/manifest.json").output).fetch("files").transform_values { |entry| entry.fetch("sha256") }
        found = container(image, architecture, "cd #{directory} && sha256sum $(ls | grep -v '^manifest.json$')").output.lines.to_h { |line| line.split.then { |digest, name| [ name, digest ] } }
        record("web-assets-match-their-manifest", architecture, mode, !listed.empty? && listed == found, "#{found.size} files")
        refused = Volume::Command.capture("docker", "run", "--rm", "--network", "none", "--platform", "linux/#{architecture}", "--env", "SECRET_KEY_BASE=#{'s' * 64}", "--entrypoint", "/usr/local/bin/shelfarr-http", image,
                                          "-experimental", "-database", "/nonexistent/db.sqlite3", "-lock-file", "/nonexistent/lock", "-library-root", "/usr/local", "-web-assets-dir", "/nonexistent", timeout: 600)
        record("shelfarr-http-refuses-a-missing-assets-folder", architecture, mode, refused.error == "refused: web-assets\n" && refused.status.exitstatus == 2, refused.error.lines.last.to_s.strip[0, 80])
      end

      def image_config(image)
        JSON.parse(Volume::Command.run!("docker", "image", "inspect", image)).first.fetch("Config")
      end

      def compare_entrypoint
        rails = image_config(@candidate_image.sub("/candidate:", "/candidate-rails:"))
        packaged = image_config(@candidate_image)
        same = %w[Entrypoint Cmd ExposedPorts User WorkingDir].all? { |key| rails[key] == packaged[key] }
        record("production-entrypoint-unchanged", host_architecture, NATIVE, same, "entrypoint=#{packaged['Entrypoint'].inspect} cmd=#{packaged['Cmd'].inspect}")
      end

      def compare_container_build_with_host_build(files)
        files.each do |name, path|
          output = Volume::Command.capture("docker", "run", "--rm", "--network", "none", "--entrypoint", "sha256sum", @candidate_image, "/usr/local/bin/#{name}")
          record("container-build-matches-host-build-#{name}", host_architecture, NATIVE, output.output.start_with?(Digest::SHA256.file(path).hexdigest), "informational: same pinned Go toolchain and flags")
        end
      end

      def check_foreign(architecture, files)
        context = File.join(@scratch, "context-#{architecture}")
        GitSource.export(@root, @commit, context)
        base = "#{Volume::Pins::IMAGE_REPOSITORY}/base-#{architecture}:#{@commit[0, 12]}"
        packaged = "#{Volume::Pins::IMAGE_REPOSITORY}/package-#{architecture}:#{@commit[0, 12]}"
        build = Volume::Command.capture("docker", "build", "--pull=false", "--platform", "linux/#{architecture}", "--target", "base", "--tag", base,
                                        "--build-arg", "RUBY_VERSION=3.3.13", "--file", File.join(context, "Dockerfile"), context, timeout: 3600)
        record("runtime-dependency-layer-builds", architecture, EMULATED, build.success?, "production Dockerfile base stage, emulated through qemu-user")
        return unless build.success?

        overlay = Volume::Command.capture("docker", "build", "--pull=false", "--platform", "linux/#{architecture}", "--tag", packaged, "--build-arg", "RAILS_IMAGE=#{base}",
                                          "--build-arg", "GO_IMAGE=#{Volume::Pins::GO_IMAGE}", "--build-arg", "BUN_IMAGE=#{Volume::Pins::BUN_IMAGE}", "--file", File.join(context, "tools/migration/packaging/Dockerfile"), context, timeout: 1800)
        record("go-binaries-layer-builds", architecture, CROSS, overlay.success?, "Go cross-compiled on the build platform, no emulated compiler")
        return unless overlay.success?

        check_image(packaged, architecture, EMULATED)
        extracted = File.join(@scratch, "extracted-#{architecture}")
        FileUtils.mkdir_p(extracted)
        files.each_key do |name|
          identical = Volume::Command.capture("docker", "run", "--rm", "--platform", "linux/#{architecture}", "--entrypoint", "sha256sum", packaged, "/usr/local/bin/#{name}").output.start_with?(Digest::SHA256.file(files.fetch(name)).hexdigest)
          record("container-build-matches-host-build-#{name}", architecture, CROSS, identical, "informational")
        end
      end
    end
  end
end
