#!/usr/bin/env ruby
# frozen_string_literal: true

# Keep the watcher input open without leaving an orphaned tail process.
# The separate group makes cleanup safe from noninteractive shells too.
Process.setpgrp
reader, writer = IO.pipe
begin
  pid = Process.spawn("bin/dev", in: reader)
  reader.close
  File.write(ARGV.fetch(0), pid.to_s)
  _, status = Process.wait2(pid)
  exit status.exitstatus || 1
ensure
  reader.close unless reader.closed?
  writer.close
end
