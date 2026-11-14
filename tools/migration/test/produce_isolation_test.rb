# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class ProduceIsolationTest < Minitest::Test
  REPO = File.expand_path("../../..", __dir__)
  TRAP = File.expand_path("support/trap_reads.rb", __dir__)

  def setup
    @scratch = Dir.mktmpdir("produce-isolation", ENV.fetch("TMPDIR", Dir.home))
    @log = File.join(@scratch, "violations.log")
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def environment(allowed)
    { "HOME" => Dir.home, "PATH" => ENV.fetch("PATH"), "LANG" => "C.UTF-8", "RUBYOPT" => "-r#{TRAP}", "TRAP_LOG" => @log, "TRAP_ALLOW" => allowed }
  end

  def violations
    File.exist?(@log) ? File.readlines(@log, chomp: true).uniq : []
  end

  def test_the_trap_sees_reads_of_credentials_keys_and_databases
    protected_reads = [ "config/credentials.yml.enc", "config/master.key", "config/credentials/test.key", "storage/test.sqlite3", "db/development.sqlite3", "storage/.encryption_keys", ".env", ".env.test", ".env.test.local" ]
    script = protected_reads.map { |path| "begin; File.binread(File.join(#{REPO.inspect}, #{path.inspect})); rescue SystemCallError; end" }.join("\n")
    _, status = Open3.capture2e(environment(@scratch), "ruby", "-e", script, unsetenv_others: true)
    assert status.success?
    assert_equal protected_reads.size, violations.size
  end

  def test_booting_and_producing_a_bundle_reads_no_repository_credentials_keys_or_databases
    out = File.join(@scratch, "bundle")
    output, status = Open3.capture2e(environment(out), "bundle", "exec", "ruby", "tools/migration/produce_fixture.rb", "--out", out, chdir: REPO, unsetenv_others: true)
    assert status.success?, output
    assert_empty violations
    assert File.exist?(File.join(out, "manifest.json"))
  end
end
