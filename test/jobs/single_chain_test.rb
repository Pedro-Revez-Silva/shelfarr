# frozen_string_literal: true

require "test_helper"

class SingleChainTest < ActiveJob::TestCase
  test "a second enqueue replaces the ready job for that class" do
    with_probe_queue do |probe, _other|
      SingleChain.enqueue(probe)
      SingleChain.enqueue(probe)

      assert_equal 1, unfinished(probe).count
    end
  end

  test "a second delayed enqueue replaces the scheduled job" do
    with_probe_queue do |probe, _other|
      SingleChain.enqueue(probe, wait: 1.minute)
      SingleChain.enqueue(probe, wait: 2.minutes)

      jobs = unfinished(probe)
      assert_equal 1, jobs.count
      assert_predicate jobs.first, :scheduled?
    end
  end

  test "positional scopes keep different ids and collapse the same id" do
    with_probe_queue do |probe, _other|
      SingleChain.enqueue(probe, 10, wait: 1.second, scope: 10)
      SingleChain.enqueue(probe, 20, wait: 1.second, scope: 20)
      SingleChain.enqueue(probe, 10, "again", wait: 1.second, scope: "10")

      assert_equal [ 10, 20 ], unfinished(probe).map { |job| positional_argument(job) }.sort
    end
  end

  test "keyword scopes collapse only matching keywords" do
    with_probe_queue do |probe, _other|
      SingleChain.enqueue(probe, wait: 1.second, scope: { post_scan: true }, post_scan: true)
      SingleChain.enqueue(probe, wait: 1.second, scope: { post_scan: false }, post_scan: false)
      SingleChain.enqueue(probe, wait: 1.second, scope: { post_scan: true }, post_scan: true)

      assert_equal 2, unfinished(probe).count
    end
  end

  test "a nil scope replaces ready jobs of that class and leaves other classes" do
    with_probe_queue do |probe, other|
      SingleChain.enqueue(other)
      SingleChain.enqueue(probe, 10, scope: 10)
      SingleChain.enqueue(probe)

      assert_equal 1, unfinished(probe).count
      assert_equal 1, unfinished(other).count
    end
  end

  test "claimed, failed, and recurring rows stay queued" do
    with_probe_queue do |probe, _other|
      process = nil
      claimed = queued_job(SingleChain.enqueue(probe, wait: 5.minutes))
      process = SolidQueue::Process.register(
        kind: "Worker",
        name: "single-chain-#{SecureRandom.hex(4)}",
        pid: Process.pid,
        hostname: "test",
        metadata: {}
      )
      claimed.scheduled_execution.destroy!
      SolidQueue::ClaimedExecution.create!(job: claimed, process: process)

      failed = queued_job(SingleChain.enqueue(probe, wait: 5.minutes))
      failed.scheduled_execution.destroy!
      SolidQueue::FailedExecution.create!(
        job: failed,
        error: { "exception_class" => "RuntimeError", "message" => "probe" }
      )

      recurring = queued_job(SingleChain.enqueue(probe, wait: 5.minutes))
      SolidQueue::RecurringExecution.create!(
        job: recurring,
        task_key: "single-chain-probe-#{Process.pid}",
        run_at: Time.current
      )

      SingleChain.enqueue(probe)

      assert SolidQueue::Job.exists?(claimed.id)
      assert SolidQueue::Job.exists?(failed.id)
      assert SolidQueue::Job.exists?(recurring.id)
      assert_equal 1, unfinished(probe).where.missing(:claimed_execution, :failed_execution, :recurring_execution).count
    ensure
      process&.destroy
    end
  end

  test "an undiscardable row is left in place" do
    with_probe_queue do |probe, _other|
      SingleChain.enqueue(probe)
      original = SolidQueue::Job.instance_method(:discard)
      SolidQueue::Job.define_method(:discard) { raise SolidQueue::Execution::UndiscardableError }
      begin
        SingleChain.enqueue(probe)
      ensure
        SolidQueue::Job.define_method(:discard, original)
      end

      assert_equal 2, unfinished(probe).count
    end
  end

  test "a queue lookup failure still enqueues" do
    with_probe_queue do |probe, _other|
      calls = 0
      original = SolidQueue::Job.method(:where)
      SolidQueue::Job.define_singleton_method(:where) do |*args, **kwargs, &block|
        calls += 1
        raise ActiveRecord::StatementInvalid, "queue offline" if calls == 1

        original.call(*args, **kwargs, &block)
      end
      begin
        SingleChain.enqueue(probe)
      ensure
        SolidQueue::Job.singleton_class.remove_method(:where)
      end

      assert_equal 1, calls
      assert_equal 1, unfinished(probe).count
    end
  end

  private

  def with_probe_queue
    original_adapter = ActiveJob::Base.queue_adapter
    original_config = SolidQueue::Record.connection_db_config
    probe = probe_job("SingleChainProbe#{Process.pid}Job")
    other = probe_job("SingleChainOtherProbe#{Process.pid}Job")

    SolidQueue::Record.establish_connection(:queue)
    ActiveJob::Base.queue_adapter = :solid_queue
    clear_jobs(probe, other)
    yield probe, other
  ensure
    clear_jobs(probe, other) if defined?(probe) && probe
    ActiveJob::Base.queue_adapter = original_adapter
    SolidQueue::Record.establish_connection(original_config) if original_config
  end

  def probe_job(name)
    return Object.const_get(name) if Object.const_defined?(name, false)

    Object.const_set(name, Class.new(ApplicationJob) do
      queue_as :default

      def perform(*_args, **_kwargs)
      end
    end)
  end

  def unfinished(job_class)
    SolidQueue::Job.where(class_name: job_class.name, finished_at: nil)
  end

  def positional_argument(job)
    Array(job.arguments["arguments"]).find { |argument| !argument.is_a?(Hash) }
  end

  def queued_job(active_job)
    SolidQueue::Job.find(active_job.provider_job_id)
  end

  def clear_jobs(*job_classes)
    ids = SolidQueue::Job.where(class_name: job_classes.compact.map(&:name)).pluck(:id)
    return if ids.empty?

    [
      SolidQueue::ReadyExecution,
      SolidQueue::ScheduledExecution,
      SolidQueue::ClaimedExecution,
      SolidQueue::FailedExecution,
      SolidQueue::RecurringExecution,
      SolidQueue::BlockedExecution
    ].each do |execution|
      execution.where(job_id: ids).delete_all
    end
    SolidQueue::Job.where(id: ids).delete_all
  end
end
