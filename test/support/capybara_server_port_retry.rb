# frozen_string_literal: true

module CapybaraServerPortRetry
  def initialize(app, *deprecated_options, port: Capybara.server_port, **options)
    @automatically_selected_port = deprecated_options[0].nil? && port.nil?
    super
  end

  def boot
    retries = 0
    begin
      super
    rescue Errno::EADDRINUSE
      raise unless @automatically_selected_port && (retries += 1) <= 3

      # Capybara closes its port-selection socket before Puma binds. If another
      # worker wins that race, replace the failed thread's port AND its checker.
      # The next boot attempt also updates Capybara's per-application port cache.
      @server_thread = nil
      @port = find_available_port(host)
      @checker = Capybara::Server::Checker.new(host, port)
      retry
    end
  end
end

Capybara::Server.prepend(CapybaraServerPortRetry)
