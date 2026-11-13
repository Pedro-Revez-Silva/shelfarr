# frozen_string_literal: true

# Makes the test server unreachable for a browser, as a stopped server or lost
# connection would: matching requests get their connection closed without any
# response, so fetches fail with a network error. Requests can also be held
# open until released, to observe a download in progress.
class ConsumerReachability
  class << self
    attr_accessor :offline, :drop, :hold
    attr_reader :requests

    def reset!
      @requests = Queue.new
      self.offline = false
      self.drop = nil
      self.hold = nil
      @released = false
    end

    def release! = @released = true
    def released? = @released
  end
  reset!

  def initialize(app)
    @app = app
  end

  def call(env)
    path = env["SCRIPT_NAME"].to_s + env["PATH_INFO"].to_s
    self.class.requests << path
    if self.class.hold&.match?(path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      sleep 0.05 until self.class.released? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
    return unreachable(env) if self.class.offline || self.class.drop&.match?(path)

    @app.call(env)
  end

  private

  def unreachable(env)
    raise "The test server must support full hijacking" unless env["rack.hijack"]

    env["rack.hijack"].call.close
    [ 200, {}, [] ]
  end
end
