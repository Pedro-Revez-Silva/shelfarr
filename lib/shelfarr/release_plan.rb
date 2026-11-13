# frozen_string_literal: true

require "date"
require "open3"
require_relative "release_channel"

module Shelfarr
  class ReleasePlan
    class GitFailed < StandardError; end

    Result = Struct.new(:should_release, :channel, :previous_tag, :head_sha, :version, :tag, :image_channel_tag,
      :prerelease, :make_latest, :title, keyword_init: true) do
      def to_github_output
        to_h.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n"
      end
    end

    def initialize(root:, today:)
      @root = root.to_s
      @today = today
    end

    def call
      channel = ReleaseChannel.load(@root)
      head_sha = git("rev-parse", "HEAD")
      previous_tag = latest_release_tag
      return skipped(channel, previous_tag, head_sha) if previous_tag && unchanged_since?(previous_tag)

      version = channel.version_for("#{date_version}.#{next_build_number}")
      Result.new(
        should_release: true,
        channel: channel.name,
        previous_tag: previous_tag,
        head_sha: head_sha,
        version: version,
        tag: "v#{version}",
        image_channel_tag: channel.image_channel_tag,
        prerelease: channel.beta?,
        make_latest: channel.stable?,
        title: channel.beta? ? "#{channel.label} (build #{version})" : "Release #{version}"
      )
    end

    private

    def skipped(channel, previous_tag, head_sha)
      Result.new(should_release: false, channel: channel.name, previous_tag: previous_tag, head_sha: head_sha,
        version: nil, tag: nil, image_channel_tag: nil, prerelease: nil, make_latest: nil, title: nil)
    end

    def date_version
      @today.strftime("%Y.%m.%d")
    end

    def next_build_number
      pattern = /\Av#{Regexp.escape(date_version)}\.(\d+)(?:#{ReleaseChannel::BETA_SUFFIX})?\z/
      used = git("tag", "--list", "v#{date_version}.*").lines.filter_map { |tag| tag.strip[pattern, 1]&.to_i }
      (used.max || 0) + 1
    end

    def latest_release_tag
      output, status = Open3.capture2e("git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD", chdir: @root)
      status.success? ? output.strip : nil
    end

    def unchanged_since?(tag)
      output, status = Open3.capture2e("git", "diff", "--quiet", tag, "HEAD", "--", chdir: @root)
      return status.exitstatus.zero? if [ 0, 1 ].include?(status.exitstatus)

      raise GitFailed, "git diff failed: #{output.strip}"
    end

    def git(*arguments)
      output, status = Open3.capture2e("git", *arguments, chdir: @root)
      raise GitFailed, "git #{arguments.first} failed: #{output.strip}" unless status.success?

      output.strip
    end
  end
end
