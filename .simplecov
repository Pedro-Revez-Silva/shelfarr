SimpleCov.start "rails" do
  enable_coverage :branch
  primary_coverage :branch
  command_name "rails-test-#{Process.pid}"

  add_filter "/config/"
  add_filter "/db/"
  add_filter "/test/"

  minimum_coverage line: 55, branch: 40
end
