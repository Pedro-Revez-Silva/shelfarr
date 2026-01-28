# frozen_string_literal: true

module Admin
  class BulkOperationsController < BaseController
    def retry_selected
      request_ids = params[:request_ids] || []
      requests = Request.with_issues.where(id: request_ids)

      count = 0
      requests.find_each do |request|
        if request.can_retry?
          request.retry_now!
          count += 1
        end
      end

      redirect_to requests_path(attention: "true"), notice: "#{count} #{'request'.pluralize(count)} queued for retry."
    end

    def cancel_selected
      request_ids = params[:request_ids] || []
      requests = Request.with_issues.where(id: request_ids)

      count = 0
      requests.find_each do |request|
        request.cancel!
        count += 1
      end

      redirect_to requests_path(attention: "true"), notice: "#{count} #{'request'.pluralize(count)} cancelled."
    end

    def retry_all
      count = 0
      Request.with_issues.find_each do |request|
        if request.can_retry?
          request.retry_now!
          count += 1
        end
      end

      redirect_to requests_path(attention: "true"), notice: "#{count} #{'request'.pluralize(count)} queued for retry."
    end
  end
end
