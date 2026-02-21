module Admin
  class DashboardController < BaseController
    def index
      @total_users = User.active.count
      @total_books = Book.count
      @pending_requests = Request.active.count
      @attention_needed = Request.needs_attention.count
      @system_health = SystemHealth.all.index_by(&:service)
      @update_check = UpdateCheckerService.cached_result
    end

    def check_updates
      @update_check = UpdateCheckerService.check(force: true)
      redirect_to admin_root_path, notice: update_notice
    end

    def run_health_check
      HealthCheckJob.perform_later
      redirect_to admin_root_path, notice: "Health check started. Results will appear shortly."
    rescue => e
      Rails.logger.error "[DashboardController] Health check failed: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      redirect_to admin_root_path, alert: "Health check failed. Check logs for details."
    end

    private

    def update_notice
      if @update_check.update_available?
        "Update available: #{@update_check.latest_version}"
      else
        "You're running the latest version (#{@update_check.current_version})"
      end
    end
  end
end
