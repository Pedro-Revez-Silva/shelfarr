# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Migration
  module Packaging
    class SourceRefused < StandardError; end

    module GitSource
      ENVIRONMENT = { "GIT_NO_REPLACE_OBJECTS" => "1", "GIT_NO_LAZY_FETCH" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null" }.freeze

      module_function

      def git(root, *arguments)
        output, status = Open3.capture2e(ENVIRONMENT, "git", "-C", root, *arguments)
        raise SourceRefused, "git #{arguments.first} failed" unless status.success?

        output.strip
      end

      def resolve(root, commit, tree: nil)
        raise SourceRefused, "commit must be a full object id" unless commit.match?(/\A[0-9a-f]{40}\z/)
        raise SourceRefused, "commit is not present locally; this tool never fetches" unless git(root, "cat-file", "-t", commit) == "commit"

        actual = git(root, "rev-parse", "#{commit}^{tree}")
        raise SourceRefused, "tree of #{commit[0, 12]} differs from its pin" if tree && actual != tree

        actual
      end

      def export(root, commit, destination)
        FileUtils.mkdir_p(destination)
        statuses = Open3.pipeline([ ENVIRONMENT, "git", "-C", root, "archive", "--format=tar", commit ], [ "tar", "-x", "-C", destination ])
        raise SourceRefused, "export of #{commit[0, 12]} failed" unless statuses.all?(&:success?)

        destination
      end

      def clean_head(root)
        raise SourceRefused, "the candidate must be built from a clean working tree" unless git(root, "status", "--porcelain", "--untracked-files=normal").empty?

        git(root, "rev-parse", "HEAD")
      end
    end
  end
end
