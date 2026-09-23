# frozen_string_literal: true

require "test_helper"

class AdapterTest < ActiveSupport::TestCase
  include OpsTestHelper

  setup do
    ActiveJob::Base.queue_adapter = :delayed_job
  end

  test "the :delayed_job adapter is the Solid Queue backed adapter" do
    assert_instance_of ActiveJob::QueueAdapters::DelayedJobAdapter, ActiveJob::Base.queue_adapter
    assert_kind_of ActiveJob::QueueAdapters::SolidQueueAdapter, ActiveJob::Base.queue_adapter
    assert_equal "DelayedJob", ActiveJob.adapter_name(ActiveJob::Base.queue_adapter)
  end

  test "perform_later enqueues into Solid Queue" do
    active_job = OpsActiveJob.perform_later("Rails")
    stored = SolidQueue::Admin.jobs(status: :pending).sole
    assert_equal "OpsActiveJob", stored.class_name
    assert_equal active_job.job_id, stored.active_job_id
    assert_equal stored.id, active_job.provider_job_id
  end

  test "supplies a wrapped class name to Delayed::Job" do
    OpsActiveJob.perform_later
    assert_match(/OpsActiveJob \[[0-9a-f-]+\] from DelayedJob\(ops\) with arguments: \[\]/, Delayed::Job.all.last.name)
  end

  test "the wrapped name omits arguments when the job does not log them" do
    Object.const_set(:OpsQuietJob, Class.new(OpsActiveJob) { self.log_arguments = false })
    OpsQuietJob.perform_later("secret")
    assert_match(/\AOpsQuietJob \[[0-9a-f-]+\] from DelayedJob\(ops\)\z/, Delayed::Job.all.last.name)
  ensure
    Object.send(:remove_const, :OpsQuietJob) if Object.const_defined?(:OpsQuietJob)
  end

  test "enqueues and executes the job" do
    OpsActiveJob.perform_later("Rails")
    ops_perform_ready_jobs
    assert_equal [ [ "Rails" ] ], OpsActiveJob.performed
  end

  test "queues the job on the correct queue" do
    OpsActiveJob.set(queue: "some_other_queue").perform_later("Rails")
    assert_equal "some_other_queue", Delayed::Job.all.last.queue
  end

  test "runs multiple queued jobs" do
    ActiveJob.perform_all_later(OpsActiveJob.new("Rails"), OpsActiveJob.new("World"))
    ops_perform_ready_jobs
    assert_equal [ [ "Rails" ], [ "World" ] ], OpsActiveJob.performed
  end

  test "does not run jobs enqueued in the future" do
    OpsActiveJob.set(wait: 5.seconds).perform_later("Rails")
    ops_perform_ready_jobs
    assert_empty OpsActiveJob.performed
  end

  test "runs jobs enqueued in the future at the specified time" do
    OpsActiveJob.set(wait: 5.seconds).perform_later("Rails")
    assert_in_delta 5.seconds.from_now, Delayed::Job.all.last.run_at, 1
  end

  test "runs jobs bulk enqueued in the future at the specified time" do
    ActiveJob.perform_all_later([ OpsActiveJob.new("Rails").set(wait: 5.seconds) ])
    assert_in_delta 5.seconds.from_now, Delayed::Job.all.last.run_at, 1
  end

  test "runs jobs with higher priority first" do
    OpsActiveJob.set(priority: 20).perform_later("1")
    OpsActiveJob.set(priority: 10).perform_later("2")
    ops_perform_ready_jobs
    assert_equal [ [ "2" ], [ "1" ] ], OpsActiveJob.performed
  end

  test "JobWrapper performs the wrapped Active Job" do
    wrapper = ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper.new(OpsActiveJob.new("direct").serialize)
    wrapper.perform
    assert_equal [ [ "direct" ] ], OpsActiveJob.performed
  end

  test "JobWrapper display_name follows the delayed_job adapter" do
    data = OpsActiveJob.new(1, "two").serialize
    wrapper = ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper.new(data)
    assert_equal "OpsActiveJob [#{data["job_id"]}] from DelayedJob(ops) with arguments: #{data["arguments"]}", wrapper.display_name
  end

  test "JobWrapper display_name tolerates unknown job classes" do
    wrapper = ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper.new("job_class" => "Missing", "job_id" => "1", "queue_name" => "q")
    assert_equal "Missing [1] from DelayedJob(q)", wrapper.display_name
  end

  test "Delayed::Job.enqueue accepts the Rails adapter JobWrapper" do
    data = OpsActiveJob.new("wrapped").serialize
    Delayed::Job.enqueue(ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper.new(data), queue: "wrapped", priority: 3)
    ops_perform_ready_jobs
    assert_equal [ [ "wrapped" ] ], OpsActiveJob.performed
  end
end
