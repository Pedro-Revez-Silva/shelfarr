# frozen_string_literal: true

module SingleChain
  class << self
    def enqueue(job_class, *args, wait: nil, scope: nil, **kwargs)
      discard_other_ready(job_class, scope)
      configured = wait.nil? ? job_class : job_class.set(wait: wait)
      if kwargs.empty?
        configured.perform_later(*args)
      else
        configured.perform_later(*args, **kwargs)
      end
    end

    private

    def discard_other_ready(job_class, scope)
      return unless solid_queue_adapter?

      SolidQueue::Job
        .where(class_name: job_class.name, finished_at: nil)
        .where.missing(:recurring_execution, :claimed_execution, :failed_execution)
        .find_each do |queued|
          next unless ready_or_scheduled?(queued)
          next unless scope_match?(queued, scope)

          queued.discard
        rescue SolidQueue::Execution::UndiscardableError, ActiveRecord::RecordNotFound
          next
        end
    rescue ActiveRecord::ActiveRecordError, NameError => error
      RemoteResult::Failed.new(error)
    end

    def ready_or_scheduled?(queued)
      return false unless queued.respond_to?(:status)

      status = queued.status
      status = status.to_sym if status.respond_to?(:to_sym)
      %i[ready scheduled].include?(status)
    end

    def scope_match?(queued, scope)
      return true if scope.nil?

      payload = queued.arguments
      payload = {} unless payload.is_a?(Hash)
      arguments = Array(payload["arguments"])
      if scope.is_a?(Hash)
        keywords = arguments.find { |argument| argument.is_a?(Hash) } || {}
        scope.all? { |key, value| keywords[key.to_s] == value }
      else
        positional = arguments.reject { |argument| argument.is_a?(Hash) }
        same_identifier?(positional.first, scope)
      end
    end

    def same_identifier?(left, right)
      return true if left == right
      return false if left.nil? || right.nil?

      left.to_s == right.to_s
    end

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end
end
