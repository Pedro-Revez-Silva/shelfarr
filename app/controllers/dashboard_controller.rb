class DashboardController < ApplicationController
  def index
    @pending_requests = Current.user.admin? ? Request.active.count : Request.for_user(Current.user).active.count
    @completed_requests = Current.user.admin? ? Request.completed.count : Request.for_user(Current.user).completed.count
    @active_downloads = Download.active.count
    @system_health = SystemHealth.all.index_by(&:service)

    # Recent activity for dashboard cards
    @recent_books = Book.acquired.order(updated_at: :desc).limit(10)
    @recent_requests = if Current.user.admin?
      Request.includes(:book, :user).order(created_at: :desc).limit(8)
    else
      Request.includes(:book).for_user(Current.user).order(created_at: :desc).limit(8)
    end
  end
end
