# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../lib/release_source"

class ReleaseSourceTest < Minitest::Test
  REPO = File.expand_path("../../..", __dir__)
  PINNED_COMMIT = "96333c6674a21701f7229c1a51038dc3b117c1a0"

  def setup
    @scratch = Dir.mktmpdir("release-source", ENV.fetch("TMPDIR", Dir.home))
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def source
    Migration::ReleaseSource.new(REPO).resolve!
  end

  def test_resolves_the_pinned_release_objects_from_local_history
    release = source
    assert_equal 100, release.migrations.size
    assert_equal "20261102120000", release.versions.last
    assert_includes release.schema_ruby, "ActiveRecord::Schema[8.1].define(version: 2026_11_02_120000)"
    refute_includes release.schema_ruby, "consumer_progresses"
    assert_equal PINNED_COMMIT, release.provenance.fetch("commit")
  end

  def test_the_release_is_an_ancestor_of_the_checkout
    _, status = Open3.capture2("git", "-C", REPO, "merge-base", "--is-ancestor", PINNED_COMMIT, "HEAD")
    assert status.success?
  end

  def test_reports_only_the_migrations_added_since_the_release
    added = source.new_migrations(File.join(REPO, "db", "migrate"))
    assert_equal 17, added.size
    assert_equal "20261107120000", added.first
    assert_equal "20261112150000", added.last
    assert added.all? { |version| version > "20261102120000" }
  end

  def test_refuses_a_missing_object_without_fetching
    empty = File.join(@scratch, "empty")
    _, status = Open3.capture2("git", "init", "--quiet", empty)
    assert status.success?
    error = assert_raises(Migration::ReleaseSource::Unavailable) { Migration::ReleaseSource.new(empty).resolve! }
    assert_match(/not present locally/, error.message)
  end

  def test_refuses_a_shipped_migration_that_changed_since_the_release
    directory = copy_migrations
    victim = File.join(directory, Dir.children(directory).grep(/\A20261102120000_/).first)
    File.write(victim, "#{File.read(victim)}\n# edited\n")
    error = assert_raises(Migration::ReleaseSource::Unavailable) { source.new_migrations(directory) }
    assert_match(/20261102120000 changed since the release/, error.message)
  end

  def test_refuses_a_released_migration_that_disappeared
    directory = copy_migrations
    FileUtils.rm(File.join(directory, Dir.children(directory).grep(/\A20261102120000_/).first))
    assert_raises(Migration::ReleaseSource::Unavailable) { source.new_migrations(directory) }
  end

  def test_refuses_a_new_migration_older_than_the_release_schema
    directory = copy_migrations
    File.write(File.join(directory, "20200101000000_late_arrival.rb"), "class LateArrival < ActiveRecord::Migration[8.1]; end\n")
    error = assert_raises(Migration::ReleaseSource::Unavailable) { source.new_migrations(directory) }
    assert_match(/not newer than the release schema/, error.message)
  end

  private

  def copy_migrations
    target = File.join(@scratch, "migrate")
    FileUtils.cp_r(File.join(REPO, "db", "migrate"), target)
    target
  end
end
