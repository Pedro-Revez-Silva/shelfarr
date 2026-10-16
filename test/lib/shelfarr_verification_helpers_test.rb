# frozen_string_literal: true

require "test_helper"
require "open3"
require "timeout"

class ShelfarrVerificationHelpersTest < ActiveSupport::TestCase
  SERVE = Rails.root.join(".cursor/skills/verify-shelfarr/serve.rb").to_s
  DRIVE = Rails.root.join(".cursor/skills/verify-shelfarr/drive.rb").to_s

  test "server keeps watcher stdin open in its own process group" do
    Dir.mktmpdir("shelfarr-serve-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "bin"))
      File.write(File.join(directory, "bin/dev"), "#!/usr/bin/env ruby\nSTDIN.read\n")
      File.chmod(0o755, File.join(directory, "bin/dev"))
      pid_file = File.join(directory, "foreman.pid")
      pid = Process.spawn(RbConfig.ruby, SERVE, pid_file, chdir: directory)
      begin
        Timeout.timeout(5) { sleep 0.01 until File.exist?(pid_file) && !File.zero?(pid_file) }
        child = File.read(pid_file).to_i
        assert_equal pid, Process.getpgid(pid)
        assert_equal pid, Process.getpgid(child)
        assert_not_equal Process.getpgrp, Process.getpgid(child)
        sleep 0.1
        assert_nil Process.waitpid(pid, Process::WNOHANG), "watcher stdin closed early"
      ensure
        Process.kill("TERM", -pid) if Process.getpgid(pid) == pid
        Timeout.timeout(5) { Process.wait(pid) }
      end
    end
  end

  test "server propagates the dev process exit status" do
    Dir.mktmpdir("shelfarr-serve-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "bin"))
      File.write(File.join(directory, "bin/dev"), "#!/usr/bin/env ruby\nexit 7\n")
      File.chmod(0o755, File.join(directory, "bin/dev"))
      _, _, status = Open3.capture3(RbConfig.ruby, SERVE, File.join(directory, "foreman.pid"), chdir: directory)
      assert_equal 7, status.exitstatus
    end
  end

  test "screenshots preserve an existing evidence file" do
    Dir.mktmpdir("shelfarr-shot-") do |directory|
      path = File.join(directory, "proof.png")
      script = <<~RUBY
        require #{DRIVE.inspect}
        page = Object.new
        def page.call(*) = { "data" => Base64.strict_encode64("new proof") }
        ShelfarrDrive.define_singleton_method(:with_page) { |_, &block| block.call(page) }
        ShelfarrDrive.shot("path" => ARGV.fetch(0))
      RUBY
      _, _, status = Open3.capture3(RbConfig.ruby, "-e", script, path)
      assert status.success?
      assert_equal "new proof", File.binread(path)

      File.binwrite(path, "original proof")
      _, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, path)
      assert_not status.success?
      assert_includes stderr, "Errno::EEXIST"
      assert_equal "original proof", File.binread(path)
    end
  end
end
