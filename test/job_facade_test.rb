# frozen_string_literal: true

require "test_helper"

class OpsLimitedJob < OpsActiveJob
  limits_concurrency key: "ops", to: 1
end

class OpsLimitedPairJob < OpsActiveJob
  limits_concurrency key: "ops", to: 2
end

class OpsLimitedFailingJob < OpsFailingActiveJob
  limits_concurrency key: "ops", to: 2
end

class OpsRunTimeLimitedJob < OpsActiveJob
  limits_run_time max: 1.hour
end

class OpsStolenDeduplicatedJob < OpsActiveJob
  deduplicates key: "ops-stolen"
end

class JobFacadeTest < ActiveSupport::TestCase
  include OpsTestHelper

  setup do
    CallbackJob.messages = []
    M::ModuleJob.runs = 0
    ops_worker_setting(:default_priority, 99)
    ops_worker_setting(:default_queue_name, "default_tracking")
    ops_worker_setting(:max_run_time, 2.minutes)
    Delayed::Job.delete_all
  end

  def create_job(options = {})
    Delayed::Job.create(options.merge(payload_object: SimpleJob.new))
  end

  def worker(name = "host:ops pid:#{Process.pid}")
    OpsWorker.new(name)
  end

  def concurrency_key_of(job)
    SolidQueue::Job.find(job.id).concurrency_key
  end

  def semaphore_value(key)
    if BACKEND == :active_record
      SolidQueue::Semaphore.find_by(key: key)&.value
    else
      SolidQueue::Mongo.collection(:semaphores).find(key: key).first&.fetch("value")
    end
  end

  test "Delayed::Job is the Solid Queue facade" do
    assert_equal Delayed::Backend::SolidQueue::Job, Delayed::Job
    assert_includes Delayed::Job.ancestors, Delayed::Backend::Base
  end

  test "sets run_at automatically if not set" do
    assert_not_nil Delayed::Job.create(payload_object: ErrorJob.new).run_at
  end

  test "does not set run_at automatically if already set" do
    later = Delayed::Job.db_time_now + 5.minutes
    job = Delayed::Job.create(payload_object: ErrorJob.new, run_at: later)
    assert_in_delta later, job.run_at, 1
  end

  test "reload reloads the payload" do
    job = Delayed::Job.enqueue payload_object: SimpleJob.new
    assert_not_equal job.payload_object.object_id, job.reload.payload_object.object_id
  end

  test "enqueue with a hash raises ArgumentError when the payload does not respond to perform" do
    assert_raises(ArgumentError) { Delayed::Job.enqueue(payload_object: Object.new) }
  end

  test "enqueue is able to set priority" do
    assert_equal 5, Delayed::Job.enqueue(payload_object: SimpleJob.new, priority: 5).priority
  end

  test "enqueue uses the default priority" do
    assert_equal 99, Delayed::Job.enqueue(payload_object: SimpleJob.new).priority
  end

  test "enqueue is able to set run_at" do
    later = Delayed::Job.db_time_now + 5.minutes
    job = Delayed::Job.enqueue payload_object: SimpleJob.new, run_at: later
    assert_in_delta later, job.run_at, 1
    assert_in_delta later, job.reload.run_at, 1
  end

  test "enqueue is able to set queue" do
    assert_equal "tracking", Delayed::Job.enqueue(payload_object: NamedQueueJob.new, queue: "tracking").queue
  end

  test "enqueue uses the default queue" do
    assert_equal "default_tracking", Delayed::Job.enqueue(payload_object: SimpleJob.new).queue
  end

  test "enqueue uses the payload object's queue" do
    assert_equal "job_tracking", Delayed::Job.enqueue(payload_object: NamedQueueJob.new).queue
  end

  test "enqueue with multiple arguments raises ArgumentError when the payload does not respond to perform" do
    assert_raises(ArgumentError) { Delayed::Job.enqueue(Object.new) }
  end

  test "enqueue increases count" do
    Delayed::Job.enqueue SimpleJob.new
    assert_equal 1, Delayed::Job.count
  end

  test "enqueue is able to set priority and run_at with deprecated arguments" do
    later = Delayed::Job.db_time_now + 5.minutes
    job = silence_warnings { Delayed::Job.enqueue SimpleJob.new, 5, later }
    assert_equal 5, job.priority
    assert_in_delta later, job.run_at, 1
  end

  test "enqueue works with jobs in modules" do
    job = Delayed::Job.enqueue M::ModuleJob.new
    assert_difference -> { M::ModuleJob.runs }, 1 do
      job.invoke_job
    end
  end

  test "enqueue does not mutate the options hash" do
    options = { priority: 1 }
    Delayed::Job.enqueue SimpleJob.new, options
    assert_equal({ priority: 1 }, options)
  end

  test "enqueue stores the job in Solid Queue" do
    job = Delayed::Job.enqueue SimpleJob.new, queue: "stored", priority: 4
    stored = SolidQueue::Admin.jobs(status: :pending).sole
    assert_equal job.id, stored.id
    assert_equal "stored", stored.queue_name
    assert_equal 4, stored.priority
  end

  test "with delay_jobs false it does not increase count" do
    Delayed::Worker.delay_jobs = false
    Delayed::Job.enqueue SimpleJob.new
    assert_equal 0, Delayed::Job.count
  end

  test "with delay_jobs false it invokes the job" do
    Delayed::Worker.delay_jobs = false
    Delayed::Job.enqueue SimpleJob.new
    assert_equal 1, SimpleJob.runs
  end

  test "with delay_jobs false it returns a job, not the result of invocation" do
    Delayed::Worker.delay_jobs = false
    assert_instance_of Delayed::Job, Delayed::Job.enqueue(SimpleJob.new)
  end

  test "callbacks run before and after the payload" do
    job = Delayed::Job.enqueue(CallbackJob.new)
    assert_equal [ "enqueue" ], CallbackJob.messages
    job.invoke_job
    assert_equal %w[ enqueue before perform success after ], CallbackJob.messages
  end

  test "callbacks run the after callback with an error" do
    job = Delayed::Job.enqueue(CallbackJob.new)
    job.payload_object.expects(:perform).raises(RuntimeError.new("fail"))
    assert_raises(RuntimeError) { job.invoke_job }
    assert_equal [ "enqueue", "before", "error: RuntimeError", "after" ], CallbackJob.messages
  end

  test "payload_object raises DeserializationError for unknown classes in the handler" do
    job = Delayed::Job.new handler: "--- !ruby/object:JobThatDoesNotExist {}"
    assert_raises(Delayed::DeserializationError) { job.payload_object }
  end

  test "payload_object raises DeserializationError for unknown structs in the handler" do
    job = Delayed::Job.new handler: "--- !ruby/struct:StructThatDoesNotExist {}"
    assert_raises(Delayed::DeserializationError) { job.payload_object }
  end

  test "payload_object raises DeserializationError on handler syntax errors" do
    job = Delayed::Job.new handler: 'message: "no ending quote'
    assert_raises(Delayed::DeserializationError) { job.payload_object }
  end

  test "reserve does not reserve failed jobs" do
    create_job attempts: 50, failed_at: Delayed::Job.db_time_now
    assert_nil Delayed::Job.reserve(worker)
  end

  test "reserve does not reserve jobs scheduled for the future" do
    create_job run_at: Delayed::Job.db_time_now + 1.minute
    assert_nil Delayed::Job.reserve(worker)
  end

  test "reserve reserves jobs scheduled for the past" do
    job = create_job run_at: Delayed::Job.db_time_now - 1.minute
    assert_equal job, Delayed::Job.reserve(worker)
  end

  test "reserve reserves jobs scheduled for the past when time zones are involved" do
    Time.zone = "America/New_York"
    job = create_job run_at: Delayed::Job.db_time_now - 1.minute
    assert_equal job, Delayed::Job.reserve(worker)
  ensure
    Time.zone = nil
  end

  test "reserve reserves scheduled jobs once they are due" do
    job = create_job run_at: Delayed::Job.db_time_now + 1.minute
    travel 2.minutes
    assert_equal job, Delayed::Job.reserve(worker)
  end

  test "reserve does not reserve jobs locked by other workers" do
    job = create_job
    assert_equal job, Delayed::Job.reserve(worker("other_worker"))
    assert_nil Delayed::Job.reserve(worker)
  end

  test "reserve reserves open jobs" do
    job = create_job
    assert_equal job, Delayed::Job.reserve(worker)
  end

  test "reserve reserves expired jobs" do
    job = create_job(locked_by: "some other worker", locked_at: Delayed::Job.db_time_now - 2.minutes - 1.minute)
    assert_equal job, Delayed::Job.reserve(worker)
  end

  test "reserve reserves own jobs" do
    job = create_job(locked_by: worker.name, locked_at: Delayed::Job.db_time_now - 1.minute)
    assert_equal job, Delayed::Job.reserve(worker)
  end

  test "reserve locks the job for the worker in Solid Queue" do
    job = create_job
    reserved = Delayed::Job.reserve(worker("locker"))
    assert_equal "locker", reserved.locked_by
    assert_not_nil reserved.locked_at

    stored = Delayed::Job.find(job.id)
    assert_equal "locker", stored.locked_by
    assert_in_delta reserved.locked_at, stored.locked_at, 1
    assert_equal 1, SolidQueue::Admin.jobs_count(status: :in_progress)
  end

  test "reserve returns nil when nothing is available" do
    assert_nil Delayed::Job.reserve(worker)
  end

  test "reserve works for plain Active Job jobs" do
    OpsActiveJob.perform_later("plain")
    job = Delayed::Job.reserve(worker)
    job.invoke_job
    assert_equal [ [ "plain" ] ], OpsActiveJob.performed
  end

  test "name is the class name of the job that was enqueued" do
    assert_equal "ErrorJob", Delayed::Job.create(payload_object: ErrorJob.new).name
  end

  test "name is the display_name of the payload" do
    assert_equal "named_job", Delayed::Job.new(payload_object: NamedJob.new).name
  end

  test "name is the instance method of a performable method" do
    skip_unless_story!
    skip_unless_performable_method!
    job = Delayed::Job.enqueue(Delayed::PerformableMethod.new(OpsStory.create!(text: "..."), :save, []))
    assert_equal "OpsStory#save", job.name
  end

  test "name is parsed from the handler on deserialization error" do
    skip_unless_story!
    skip_unless_performable_method!
    story = OpsStory.create!(text: "...")
    job = Delayed::Job.enqueue(Delayed::PerformableMethod.new(story, :tell, []))
    story.destroy
    assert_equal "Delayed::PerformableMethod", job.reload.name
  end

  test "name of a plain Active Job job follows the delayed_job adapter" do
    active_job = OpsActiveJob.perform_later
    assert_match(/\AOpsActiveJob \[#{active_job.job_id}\] from DelayedJob\(ops\) with arguments: \[\]\z/, Delayed::Job.last.name)
  end

  test "fetches jobs ordered by priority" do
    10.times { Delayed::Job.enqueue SimpleJob.new, priority: rand(10) }
    jobs = 10.times.map { Delayed::Job.reserve(worker).tap(&:destroy) }
    assert_equal 10, jobs.compact.size
    jobs.each_cons(2) { |a, b| assert_operator a.priority, :<=, b.priority }
  end

  test "only finds jobs greater than or equal to min priority" do
    ops_worker_setting(:min_priority, 5)
    [ 4, 5, 6 ].shuffle.each { |priority| create_job priority: priority }
    2.times do
      job = Delayed::Job.reserve(worker)
      assert_operator job.priority, :>=, 5
      job.destroy
    end
    assert_nil Delayed::Job.reserve(worker)
  end

  test "only finds jobs less than or equal to max priority" do
    ops_worker_setting(:max_priority, 5)
    [ 4, 5, 6 ].shuffle.each { |priority| create_job priority: priority }
    2.times do
      job = Delayed::Job.reserve(worker)
      assert_operator job.priority, :<=, 5
      job.destroy
    end
    assert_nil Delayed::Job.reserve(worker)
  end

  test "sets job priority based on queue_attributes" do
    ops_worker_setting(:queue_attributes, { "job_tracking" => { priority: 4 } }.with_indifferent_access)
    assert_equal 4, Delayed::Job.enqueue(payload_object: NamedQueueJob.new).priority
  end

  test "passed priority overrides queue_attributes" do
    ops_worker_setting(:queue_attributes, { "job_tracking" => { priority: 4 } }.with_indifferent_access)
    assert_equal 10, Delayed::Job.enqueue(payload_object: NamedQueueJob.new, priority: 10).priority
  end

  test "clear_locks! clears locks for the given worker" do
    job = create_job(locked_by: "worker1", locked_at: Delayed::Job.db_time_now)
    Delayed::Job.clear_locks!("worker1")
    assert_equal job, Delayed::Job.reserve(worker)
  end

  test "clear_locks! does not clear locks for other workers" do
    job = create_job(locked_by: "worker1", locked_at: Delayed::Job.db_time_now)
    Delayed::Job.clear_locks!("different_worker")
    assert_not_equal job, Delayed::Job.reserve(worker)
  end

  test "unlock clears locks" do
    job = create_job(locked_by: "worker", locked_at: Delayed::Job.db_time_now)
    job.unlock
    assert_nil job.locked_by
    assert_nil job.locked_at
  end

  test "large handler has an id" do
    skip_unless_performable_method!
    text = "Lorem ipsum dolor sit amet. " * 1000
    assert_not_nil Delayed::Job.enqueue(Delayed::PerformableMethod.new(text, :length, {})).id
  end

  test "named queues: a worker with one queue only reserves its queue" do
    ops_worker_setting(:queues, [ "large" ])
    large = create_job(queue: "large")
    create_job(queue: "small")
    assert_equal large, Delayed::Job.reserve(worker).tap(&:destroy)
    assert_nil Delayed::Job.reserve(worker)
  end

  test "named queues: a worker with two queues reserves both" do
    ops_worker_setting(:queues, %w[ large small ])
    create_job(queue: "large")
    create_job(queue: "small")
    create_job(queue: "medium")
    create_job
    reserved = 4.times.filter_map { Delayed::Job.reserve(worker)&.tap(&:destroy) }
    assert_equal %w[ large small ], reserved.map(&:queue).sort
  end

  test "named queues: a worker without queues reserves everything" do
    ops_worker_setting(:queues, [])
    create_job(queue: "one")
    create_job(queue: "two")
    create_job
    assert_equal 3, 4.times.filter_map { Delayed::Job.reserve(worker)&.tap(&:destroy) }.size
  end

  test "named queues: paused Solid Queue queues are not reserved" do
    create_job(queue: "paused")
    SolidQueue::Queue.find_by_name("paused").pause
    assert_nil Delayed::Job.reserve(worker)
  end

  test "max_attempts is not defined" do
    assert_nil Delayed::Job.enqueue(SimpleJob.new).max_attempts
  end

  test "max_attempts uses the payload value when defined" do
    job = Delayed::Job.enqueue SimpleJob.new
    job.payload_object.expects(:max_attempts).returns(99)
    assert_equal 99, job.max_attempts
  end

  test "max_run_time is not defined" do
    assert_nil Delayed::Job.enqueue(SimpleJob.new).max_run_time
  end

  test "max_run_time uses the payload value when defined" do
    ops_worker_setting(:max_run_time, 4.hours)
    job = Delayed::Job.enqueue SimpleJob.new
    job.payload_object.expects(:max_run_time).returns(30.minutes)
    assert_equal 30.minutes, job.max_run_time
  end

  test "destroy_failed_jobs? is true by default" do
    ops_worker_setting(:destroy_failed_jobs, true)
    assert Delayed::Job.enqueue(SimpleJob.new).destroy_failed_jobs?
  end

  test "destroy_failed_jobs? uses the payload value when defined" do
    job = Delayed::Job.enqueue SimpleJob.new
    job.payload_object.expects(:destroy_failed_jobs?).returns(false)
    assert_equal false, job.destroy_failed_jobs?
  end

  test "reload reloads changed attributes of records" do
    skip_unless_story!
    skip_unless_performable_method!
    story = OpsStory.create!(text: "hello")
    job = Delayed::Job.enqueue(Delayed::PerformableMethod.new(story, :tell, []))
    story.update!(text: "goodbye")
    assert_equal "goodbye", job.reload.payload_object.object.text
  end

  test "reload raises DeserializationError for destroyed records" do
    skip_unless_story!
    skip_unless_performable_method!
    story = OpsStory.create!(text: "hello")
    job = Delayed::Job.enqueue(Delayed::PerformableMethod.new(story, :tell, []))
    story.destroy
    assert_raises(Delayed::DeserializationError) { job.reload.payload_object }
  end

  test "reload raises when the job is gone" do
    job = create_job
    job.destroy
    assert_raises(Delayed::Backend::SolidQueue::RecordNotFound) { job.reload }
  end

  test "attributes map to the Solid Queue job" do
    freeze_time
    job = Delayed::Job.enqueue(SimpleJob.new, priority: 3, queue: "attrs", run_at: 1.hour.from_now)
    loaded = Delayed::Job.find(job.id)

    assert_equal job.id, loaded.id
    assert_equal 3, loaded.priority
    assert_equal "attrs", loaded.queue
    assert_equal 0, loaded.attempts
    assert_in_delta 1.hour.from_now, loaded.run_at, 1
    assert_in_delta Time.current, loaded.created_at, 1
    assert_not_nil loaded.updated_at
    assert_nil loaded.locked_at
    assert_nil loaded.locked_by
    assert_nil loaded.failed_at
    assert_nil loaded.last_error
    assert_not loaded.failed?
    assert_includes loaded.handler, "SimpleJob"
    assert_instance_of SimpleJob, loaded.payload_object
  end

  test "attempts map to Active Job executions" do
    OpsActiveJob.new.tap { |job| job.executions = 3 }.enqueue
    assert_equal 3, Delayed::Job.last.attempts
  end

  test "failed Solid Queue jobs expose failed_at, last_error and attempts" do
    OpsFailingActiveJob.perform_later
    ops_perform_ready_jobs

    job = Delayed::Job.last
    assert job.failed?
    assert_not_nil job.failed_at
    assert_equal 1, job.attempts
    assert_match(/\Aops failure\n.*ops_test_helper\.rb:\d+/, job.last_error)
  end

  test "handler of a plain Active Job job is the delayed_job adapter wrapper" do
    active_job = OpsActiveJob.perform_later("a", 1)
    job = Delayed::Job.last
    assert_match %r{\A--- !ruby/object:ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper}, job.handler
    assert_instance_of ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper, job.payload_object
    assert_equal active_job.job_id, job.payload_object.job_data["job_id"]
  end

  test "count, all and where cover every unfinished Solid Queue job" do
    OpsFailingActiveJob.perform_later
    ops_perform_ready_jobs
    create_job(queue: "a")
    create_job(queue: "b", run_at: 1.hour.from_now)
    OpsActiveJob.perform_later
    create_job(queue: "a")

    assert_equal 5, Delayed::Job.count
    assert_equal 5, Delayed::Job.all.to_a.size
    assert_equal 2, Delayed::Job.where(queue: "a").count
    assert_equal 1, Delayed::Job.where.not(failed_at: nil).count
    assert_equal 4, Delayed::Job.where(failed_at: nil).count
  end

  test "finished jobs are not visible" do
    OpsActiveJob.perform_later
    ops_perform_ready_jobs
    assert_equal 0, Delayed::Job.count
    assert_nil Delayed::Job.first
  end

  test "where filters by priority values, arrays and ranges" do
    [ 1, 5, 9 ].each { |priority| create_job(priority: priority) }
    assert_equal [ 5 ], Delayed::Job.where(priority: 5).map(&:priority)
    assert_equal [ 1, 9 ], Delayed::Job.where(priority: [ 1, 9 ]).map(&:priority).sort
    assert_equal [ 1, 5 ], Delayed::Job.where(priority: 0..5).map(&:priority).sort
    assert_equal [ 5, 9 ], Delayed::Job.where(priority: 5..).map(&:priority).sort
  end

  test "where filters by attempts" do
    create_job
    create_job(attempts: 2)
    assert_equal [ 2 ], Delayed::Job.where(attempts: 2).map(&:attempts)
    assert_equal 1, Delayed::Job.where(attempts: 0).count
    assert_equal 1, Delayed::Job.where.not(attempts: 0).count
  end

  test "where filters by run_at and created_at" do
    create_job(run_at: 1.hour.ago)
    create_job(run_at: 1.hour.from_now)
    assert_equal 1, Delayed::Job.where(run_at: ..Time.current).count
    assert_equal 2, Delayed::Job.where(created_at: 1.minute.ago..).count
  end

  test "where filters by locked_by and locked_at" do
    create_job(locked_by: "w1", locked_at: Time.current)
    create_job
    assert_equal 1, Delayed::Job.where(locked_by: "w1").count
    assert_equal 1, Delayed::Job.where(locked_at: nil).count
    assert_equal 1, Delayed::Job.where.not(locked_by: nil).count
  end

  test "where accepts simple SQL fragments" do
    create_job
    create_job(attempts: 1, failed_at: Time.current)
    assert_equal 1, Delayed::Job.where("failed_at IS NOT NULL").count
    assert_equal 1, Delayed::Job.where("failed_at IS NULL").count
    assert_equal 1, Delayed::Job.where("attempts = 0 AND created_at < ?", 1.minute.from_now).count
    assert_equal 2, Delayed::Job.where("priority >= ?", 0).count
  end

  test "where rejects SQL it can not translate" do
    assert_raises(ArgumentError) { Delayed::Job.where("handler LIKE '%x%' OR 1=1").count }
  end

  test "where rejects unknown attributes" do
    assert_raises(ArgumentError) { Delayed::Job.where(nope: 1).count }
  end

  test "where chains" do
    create_job(queue: "a", priority: 1)
    create_job(queue: "a", priority: 2)
    create_job(queue: "b", priority: 1)
    assert_equal 1, Delayed::Job.where(queue: "a").where(priority: 1).count
  end

  test "order, first, last, limit and offset" do
    jobs = [ 3, 1, 2 ].map { |priority| create_job(priority: priority) }
    assert_equal jobs.first, Delayed::Job.first
    assert_equal jobs.last, Delayed::Job.last
    assert_equal [ 1, 2, 3 ], Delayed::Job.order(:priority).map(&:priority)
    assert_equal [ 3, 2, 1 ], Delayed::Job.order(priority: :desc).map(&:priority)
    assert_equal [ 1, 2 ], Delayed::Job.order("priority ASC, run_at ASC").limit(2).map(&:priority)
    assert_equal [ 2 ], Delayed::Job.order(:priority).offset(1).limit(1).map(&:priority)
    assert_equal jobs.first(2), Delayed::Job.first(2)
    assert_equal jobs.last(2), Delayed::Job.last(2)
  end

  test "order merges jobs across Solid Queue states" do
    failed = create_job(priority: 2, failed_at: Time.current)
    scheduled = create_job(priority: 1, run_at: 1.hour.from_now)
    ready = create_job(priority: 3)
    locked = create_job(priority: 0, locked_by: "w", locked_at: Time.current)
    assert_equal [ locked, scheduled, failed, ready ], Delayed::Job.order(:priority).to_a
    assert_equal [ failed, scheduled ], Delayed::Job.order(:priority).offset(1).limit(2).to_a.sort_by(&:priority).reverse
  end

  test "order by attempts sorts in memory" do
    create_job(attempts: 2)
    create_job(attempts: 1)
    assert_equal [ 1, 2 ], Delayed::Job.order(:attempts).map(&:attempts)
  end

  test "find returns the job" do
    job = create_job
    assert_equal job, Delayed::Job.find(job.id)
    assert_equal job, Delayed::Job.find(job.id.to_s)
  end

  test "find raises for unknown and finished jobs" do
    assert_raises(Delayed::Backend::SolidQueue::RecordNotFound) { Delayed::Job.find(0) }
    assert_raises(Delayed::Backend::SolidQueue::RecordNotFound) { Delayed::Job.find("nope") }

    OpsActiveJob.perform_later
    id = SolidQueue::Admin.jobs(status: :pending).sole.id
    ops_perform_ready_jobs
    assert_raises(Delayed::Backend::SolidQueue::RecordNotFound) { Delayed::Job.find(id) }
  end

  test "RecordNotFound is the Active Record error on the SQL backend and Solid Queue's otherwise" do
    parent = BACKEND == :active_record ? ActiveRecord::RecordNotFound : SolidQueue::RecordNotFound
    assert_operator Delayed::Backend::SolidQueue::RecordNotFound, :<, parent
  end

  test "find follows a job rescheduled by Active Job to its latest execution" do
    active_job = OpsActiveJob.perform_later
    first_id = Delayed::Job.last.id
    ops_perform_ready_jobs
    active_job.executions = 1
    active_job.enqueue
    assert_equal 1, Delayed::Job.find(first_id).attempts
    assert_not_equal first_id, Delayed::Job.find(first_id).id
  end

  test "find_by and exists?" do
    job = create_job(queue: "find_by")
    assert_equal job, Delayed::Job.find_by(queue: "find_by")
    assert_nil Delayed::Job.find_by(queue: "missing")
    assert Delayed::Job.where(queue: "find_by").exists?
    assert_not Delayed::Job.where(queue: "missing").exists?
  end

  test "pluck and ids" do
    jobs = [ create_job(priority: 1), create_job(priority: 2) ]
    assert_equal jobs.map(&:id), Delayed::Job.ids
    assert_equal [ 1, 2 ], Delayed::Job.pluck(:priority)
    assert_equal [ [ jobs.first.id, 1 ], [ jobs.last.id, 2 ] ], Delayed::Job.pluck(:id, :priority)
  end

  test "delete_all removes matching jobs in every state" do
    create_job(queue: "gone")
    create_job(queue: "gone", run_at: 1.hour.from_now)
    create_job(queue: "gone", failed_at: Time.current)
    create_job(queue: "gone", locked_by: "w", locked_at: Time.current)
    kept = create_job(queue: "kept")

    assert_equal 4, Delayed::Job.where(queue: "gone").delete_all
    assert_equal [ kept ], Delayed::Job.all.to_a
    assert_equal 1, ops_unfinished_count
  end

  test "class delete_all removes plain Active Job jobs too" do
    OpsActiveJob.perform_later
    create_job
    assert_equal 2, Delayed::Job.delete_all
    assert_equal 0, ops_unfinished_count
  end

  test "destroy_all destroys each job" do
    2.times { create_job }
    assert_equal 2, Delayed::Job.destroy_all.size
    assert_equal 0, Delayed::Job.count
  end

  test "destroy removes a job in any state" do
    [ create_job, create_job(run_at: 1.hour.from_now), create_job(failed_at: Time.current),
      create_job(locked_by: "w", locked_at: Time.current) ].each(&:destroy)
    assert_equal 0, ops_unfinished_count
  end

  test "delete_all of claimed jobs releases their deduplication keys" do
    Object.const_set(:OpsDedupJob, Class.new(OpsActiveJob) { deduplicates key: "ops-dedup" })
    OpsDedupJob.perform_later
    Delayed::Job.reserve(worker)
    assert_equal 1, Delayed::Job.delete_all
    assert OpsDedupJob.perform_later.successfully_enqueued?
  ensure
    Object.send(:remove_const, :OpsDedupJob) if Object.const_defined?(:OpsDedupJob)
  end

  test "destroy of a reserved job removes the claim" do
    create_job
    Delayed::Job.reserve(worker).destroy
    assert_equal 0, ops_unfinished_count
  end

  test "db_time_now is the current time" do
    freeze_time
    assert_equal Time.current, Delayed::Job.db_time_now
  end

  test "ready_to_run returns jobs the worker may run" do
    open = create_job
    own = create_job(locked_by: "me", locked_at: Time.current)
    expired = create_job(locked_by: "other", locked_at: 3.minutes.ago)
    create_job(locked_by: "other", locked_at: Time.current)
    create_job(run_at: 1.hour.from_now)
    create_job(failed_at: Time.current)

    assert_equal [ open, own, expired ].map(&:id).sort, Delayed::Job.ready_to_run("me", 2.minutes).map(&:id).sort
  end

  test "before_fork and after_fork reset connections" do
    SolidQueue.expects(:after_fork!)
    Delayed::Job.before_fork
    Delayed::Job.after_fork
  end

  test "new builds an unsaved job" do
    job = Delayed::Job.new(payload_object: SimpleJob.new, priority: 2, queue: "unsaved")
    assert job.new_record?
    assert_not job.persisted?
    assert_nil job.id
    assert_equal 2, job.priority
    assert_equal 0, Delayed::Job.count
  end

  test "save enqueues through Delayed::JobWrapper.enqueue_payload" do
    payload = SimpleJob.new
    Delayed::JobWrapper.expects(:enqueue_payload).with(payload, has_entries(queue: "q", priority: 2)).returns(OpsActiveJob.perform_later)
    job = Delayed::Job.new(payload_object: payload, priority: 2, queue: "q")
    assert job.save
    assert job.persisted?
    assert_not_nil job.id
  end

  test "save of an Active Job adapter wrapper enqueues the Active Job itself" do
    data = OpsActiveJob.new("wrapped").serialize
    job = Delayed::Job.enqueue(ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper.new(data), queue: "wrapped", priority: 7)
    stored = SolidQueue::Admin.jobs(status: :pending).sole
    assert_equal "OpsActiveJob", stored.class_name
    assert_equal data["job_id"], stored.active_job_id
    assert_equal [ "wrapped", 7 ], [ job.queue, job.priority ]
  end

  test "save! of a persisted job reschedules it like Delayed::Worker#reschedule" do
    create_job
    job = Delayed::Job.reserve(worker)
    job.attempts += 1
    job.error = RuntimeError.new("did not work").tap { |e| e.set_backtrace([ "sample_jobs.rb:1:in 'perform'" ]) }
    job.run_at = 5.minutes.from_now
    job.unlock
    job.save!

    job.reload
    assert_equal 1, job.attempts
    assert_match(/did not work/, job.last_error)
    assert_in_delta 5.minutes.from_now, job.run_at, 1
    assert_nil job.locked_by
    assert_nil job.locked_at
    assert_not job.failed?
    assert_equal 1, SolidQueue::Admin.jobs_count(status: :scheduled)
  end

  test "fail! marks the job failed in Solid Queue like Delayed::Worker#failed" do
    create_job
    job = Delayed::Job.reserve(worker)
    job.attempts += 1
    job.error = RuntimeError.new("did not work").tap { |e| e.set_backtrace([ "a.rb:1", "b.rb:2" ]) }
    job.fail!

    job.reload
    assert job.failed?
    assert_equal 1, job.attempts
    assert_equal "did not work\na.rb:1\nb.rb:2", job.last_error
    assert_equal 1, SolidQueue::Admin.failures_count
  end

  test "update and update_all change persisted jobs" do
    job = create_job(priority: 1)
    job.update!(priority: 4)
    assert_equal 4, job.reload.priority
    assert_equal 1, Delayed::Job.where(priority: 4).update_all(queue: "moved")
    assert_equal "moved", job.reload.queue
  end

  test "updating a locked job keeps its claim" do
    create_job(priority: 1)
    reserved = Delayed::Job.reserve(worker("holder"))
    claim = -> { BACKEND == :active_record ? SolidQueue::ClaimedExecution.find_by(job_id: reserved.id)&.id : SolidQueue::Job.find(reserved.id).claim_token }
    original_claim = claim.call

    Delayed::Job.find(reserved.id).update!(priority: 7, queue: "moved")

    assert_equal original_claim, claim.call

    job = Delayed::Job.find(reserved.id)
    assert_equal [ 7, "moved", "holder" ], [ job.priority, job.queue, job.locked_by ]
    assert_equal 1, SolidQueue::Admin.jobs_count(status: :in_progress)
    assert_equal 0, SolidQueue::Admin.jobs_count(status: :pending)
  end

  test "save refuses to rewrite a job a Solid Queue worker claimed after it was loaded" do
    create_job(priority: 1)
    job = Delayed::Job.first
    SolidQueue::ReadyExecution.claim("*", 1, ops_process("sq-worker").id)

    job.priority = 9
    assert_equal false, job.save
    assert_raises(Delayed::Backend::SolidQueue::StaleJobError) { job.save! }

    current = Delayed::Job.first
    assert_equal [ 1, "sq-worker" ], [ current.priority, current.locked_by ]
    assert_equal 1, SolidQueue::Admin.jobs_count(status: :in_progress)
  end

  test "save refuses to reschedule a claimed job whose claim moved to another process" do
    create_job
    job = Delayed::Job.reserve(worker("first"))
    Delayed::Job.first.tap { |loaded| travel(3.minutes) { assert loaded.lock_exclusively!(2.minutes, "second") } }

    job.unlock
    job.run_at = 1.hour.from_now
    assert_equal false, job.save
    assert_equal "second", Delayed::Job.first.locked_by
  end

  test "update_all counts only the jobs it could rewrite" do
    create_job(queue: "a")
    create_job(queue: "a")
    stale = Delayed::Job.where(queue: "a").to_a
    SolidQueue::ReadyExecution.claim("*", 1, ops_process("sq-worker").id)
    Delayed::Backend::SolidQueue::Relation.any_instance.stubs(:to_a).returns(stale)

    assert_equal 1, Delayed::Job.where(queue: "a").update_all(priority: 5)
  end

  test "retrying a failed job by clearing failed_at makes it runnable again" do
    job = create_job(attempts: 3, failed_at: Time.current)
    job.update!(failed_at: nil, attempts: 0)
    assert_equal job, Delayed::Job.reserve(worker)
  end

  test "lock_exclusively! claims the job only once" do
    create_job
    first = Delayed::Job.first
    second = Delayed::Job.first
    assert first.lock_exclusively!(2.minutes, "a")
    assert_not second.lock_exclusively!(2.minutes, "b")
  end

  test "lock_exclusively! refreshes own locks and steals expired ones" do
    create_job(locked_by: "a", locked_at: 3.minutes.ago)
    job = Delayed::Job.first
    assert job.lock_exclusively!(2.minutes, "a")
    assert_in_delta Time.current, Delayed::Job.first.locked_at, 1

    assert_not Delayed::Job.first.lock_exclusively!(2.minutes, "b")
    travel 3.minutes
    assert Delayed::Job.first.lock_exclusively!(2.minutes, "b")
    assert_equal "b", Delayed::Job.first.locked_by
  end

  test "stealing an expired claim clears the previous run's watchdog deadline" do
    create_job(locked_by: "a", locked_at: 3.minutes.ago)
    job_id = Delayed::Job.first.id
    if BACKEND == :active_record
      SolidQueue::ClaimedExecution.where(job_id: job_id).update_all(started_at: 3.minutes.ago, timeout_at: 1.minute.ago)
    else
      SolidQueue::Mongo.collection(:jobs).update_one({ _id: BSON::ObjectId.from_string(job_id) },
        { "$set" => { started_at: 3.minutes.ago, timeout_at: 1.minute.ago } })
    end

    assert Delayed::Job.first.lock_exclusively!(2.minutes, "b")

    claim = BACKEND == :active_record ? SolidQueue::ClaimedExecution.find_by(job_id: job_id) : SolidQueue::Job.find(job_id)
    assert_nil claim.started_at
    assert_nil claim.timeout_at
  end

  test "reserve does not take over expired claims of live Solid Queue workers" do
    create_job
    SolidQueue::ReadyExecution.claim("*", 1, ops_process("sq-live").id)
    travel 3.minutes

    assert_nil Delayed::Job.reserve(worker)
    assert_not Delayed::Job.first.lock_exclusively!(2.minutes, worker.name)
    assert_equal "sq-live", Delayed::Job.first.locked_by
  end

  test "reserve takes over expired claims of Solid Queue workers that stopped heartbeating" do
    job = create_job
    SolidQueue::ReadyExecution.claim("*", 1, ops_process("sq-dead").id)
    travel SolidQueue.process_alive_threshold + 1.minute

    assert_equal job, Delayed::Job.reserve(worker)
    assert_equal worker.name, Delayed::Job.first.locked_by
  end

  test "reservation processes keep heartbeating while a job runs" do
    SolidQueue.stubs(:process_heartbeat_interval).returns(0.05)
    create_job
    Delayed::Job.reserve(worker("beating"))
    process = Delayed::Job.store.find_process("beating")
    first = process.last_heartbeat_at

    beat = 50.times.any? do
      sleep 0.05
      Delayed::Job.store.find_process("beating").last_heartbeat_at > first
    end
    assert beat, "the reservation process was not heartbeated"
  ensure
    Delayed::Job.clear_locks!("beating")
  end

  test "clear_locks! stops the reservation heartbeat" do
    SolidQueue.stubs(:process_heartbeat_interval).returns(0.05)
    create_job
    Delayed::Job.reserve(worker("stopping"))
    process_id = Delayed::Job.store.find_process("stopping").id

    Delayed::Job.clear_locks!("stopping")

    assert_nil Delayed::Job.send(:heartbeats)[process_id.to_s]
  end

  test "rewriting a ready job limited to one keeps its own concurrency slot" do
    OpsLimitedJob.perform_later("limited")
    key = concurrency_key_of(Delayed::Job.last)
    assert_equal 0, semaphore_value(key)

    assert Delayed::Job.last.update(priority: 5)

    assert_equal [ 1, 0 ], [ SolidQueue::Admin.jobs_count(status: :pending), SolidQueue::Admin.jobs_count(status: :blocked) ]
    assert_equal 0, semaphore_value(key)
    assert_equal 5, Delayed::Job.last.priority
    ops_perform_ready_jobs
    assert_equal [ [ "limited" ] ], OpsActiveJob.performed
  end

  test "rewriting a ready job with a higher limit uses one slot, not two" do
    OpsLimitedPairJob.perform_later
    key = concurrency_key_of(Delayed::Job.last)
    assert_equal 1, semaphore_value(key)

    assert Delayed::Job.last.update(run_at: 1.minute.ago, queue: "moved")

    assert_equal 1, semaphore_value(key)
    assert_equal 1, SolidQueue::Admin.jobs_count(status: :pending)
    assert_equal "moved", SolidQueue::Admin.jobs(status: :pending).sole.queue_name
  end

  test "rescheduling a ready limited job releases its slot to the next blocked job" do
    OpsLimitedJob.perform_later("first")
    OpsLimitedJob.perform_later("second")
    first, second = Delayed::Job.order(:id).to_a
    assert_equal :blocked, second.status

    assert first.update(run_at: 1.hour.from_now)

    assert_equal :scheduled, Delayed::Job.find(first.id).status
    assert_equal :ready, Delayed::Job.find(second.id).status
    assert_equal 0, semaphore_value(concurrency_key_of(first))
  end

  test "failing a ready limited job releases its slot" do
    OpsLimitedJob.perform_later
    job = Delayed::Job.last

    job.error = RuntimeError.new("gave up")
    job.fail!

    assert_equal :failed, Delayed::Job.find(job.id).status
    assert_equal 1, semaphore_value(concurrency_key_of(job))
  end

  test "rescheduling a reserved limited job releases its slot to the next blocked job" do
    OpsLimitedJob.perform_later("first")
    OpsLimitedJob.perform_later("second")
    reserved = Delayed::Job.reserve(worker)
    second = Delayed::Job.where.not(id: reserved.id).sole

    reserved.unlock
    reserved.run_at = 1.hour.from_now
    reserved.save!

    assert_equal :scheduled, Delayed::Job.find(reserved.id).status
    assert_equal :ready, Delayed::Job.find(second.id).status
    assert_equal 0, semaphore_value(concurrency_key_of(reserved))
  end

  test "unlocking a reserved limited job back to ready keeps its slot" do
    OpsLimitedJob.perform_later
    reserved = Delayed::Job.reserve(worker)

    reserved.unlock
    reserved.run_at = 1.minute.ago
    reserved.save!

    assert_equal :ready, Delayed::Job.find(reserved.id).status
    assert_equal 0, semaphore_value(concurrency_key_of(reserved))
  end

  test "making a failed limited job runnable again acquires exactly one slot" do
    OpsLimitedFailingJob.perform_later
    ops_perform_ready_jobs
    job = Delayed::Job.last
    assert_equal 2, semaphore_value(concurrency_key_of(job))

    assert job.update(failed_at: nil, attempts: 0)

    assert_equal :ready, Delayed::Job.find(job.id).status
    assert_equal 1, semaphore_value(concurrency_key_of(job))
  end

  test "rewriting a blocked limited job keeps it blocked until the slot frees, then promotes it" do
    OpsLimitedJob.perform_later("first")
    OpsLimitedJob.perform_later("second")
    blocked = Delayed::Job.order(:id).last

    assert blocked.update(priority: 3)

    assert_equal :blocked, Delayed::Job.find(blocked.id).status
    assert_equal 0, semaphore_value(concurrency_key_of(blocked))
    ops_perform_ready_jobs
    assert_equal [ [ "first" ], [ "second" ] ], OpsActiveJob.performed
  end

  test "deleting a reserved limited job releases its slot to the next blocked job" do
    OpsLimitedJob.perform_later("first")
    OpsLimitedJob.perform_later("second")
    reserved = Delayed::Job.reserve(worker)
    second = Delayed::Job.where.not(id: reserved.id).sole

    reserved.destroy

    assert_equal :ready, Delayed::Job.find(second.id).status
    assert_equal 0, semaphore_value(concurrency_key_of(second))
    ops_perform_ready_jobs
    assert_equal [ [ "second" ] ], OpsActiveJob.performed
  end

  { "run-time limited" => OpsRunTimeLimitedJob, "deduplicated" => OpsStolenDeduplicatedJob }.each do |kind, job_class|
    test "a stolen claim of a #{kind} job runs when Solid Queue performs it" do
      job_class.perform_later("stolen")
      job_id = Delayed::Job.last.id
      SolidQueue::ReadyExecution.claim("*", 1, ops_process("sq-dead").id)
      if BACKEND == :active_record
        SolidQueue::ClaimedExecution.where(job_id: job_id).update_all(started_at: Time.current, timeout_at: 1.hour.from_now)
      else
        SolidQueue::Mongo.collection(:jobs).update_one({ _id: BSON::ObjectId.from_string(job_id) },
          { "$set" => { started_at: Time.current, timeout_at: 1.hour.from_now } })
      end
      travel SolidQueue.process_alive_threshold + 1.minute

      assert Delayed::Job.first.lock_exclusively!(2.minutes, "thief")
      claim = BACKEND == :active_record ? SolidQueue::ClaimedExecution.find_by!(job_id: job_id) : SolidQueue::ClaimedExecution.find(job_id)
      assert_nil claim.started_at
      assert_nil claim.timeout_at
      claim.perform

      assert_equal [ [ "stolen" ] ], OpsActiveJob.performed
      assert_equal 0, ops_unfinished_count
    end
  end

  test "facade queries emit no per-job queries for failed and locked jobs" do
    skip "counts Active Record queries" unless BACKEND == :active_record
    5.times { create_job(failed_at: Time.current) }
    5.times { |i| create_job(locked_by: "w#{i}", locked_at: Time.current) }
    queries = 0
    counter = ->(*) { queries += 1 }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Delayed::Job.all.each { |job| [ job.last_error, job.locked_by, job.failed_at, job.attempts ] }
    end
    assert_operator queries, :<=, 12
  end

  test "worker integration records last_error and fails the job" do
    skip "needs Delayed::Worker#run" unless Delayed::Worker.method_defined?(:run)
    Delayed::Worker.destroy_failed_jobs = false
    Delayed::Worker.max_attempts = 1
    job = Delayed::Job.enqueue(ErrorJob.new, run_at: Delayed::Job.db_time_now - 1)
    Delayed::Worker.new.run(job)
    job.reload
    assert_match(/did not work/, job.last_error)
    assert_equal 1, job.attempts
    assert job.failed?
  end

  test "worker integration re-schedules jobs after failing" do
    skip "needs Delayed::Worker#run" unless Delayed::Worker.method_defined?(:run)
    job = Delayed::Job.enqueue(ErrorJob.new, run_at: Delayed::Job.db_time_now - 1)
    Delayed::Worker.new.run(job)
    job.reload
    assert_match(/did not work/, job.last_error)
    assert_equal 1, job.attempts
    assert_nil job.locked_by
  end

  test "worker integration re-schedules with the handler provided time" do
    skip "needs Delayed::Worker#run" unless Delayed::Worker.method_defined?(:run)
    job = Delayed::Job.enqueue(CustomRescheduleJob.new(99.minutes))
    Delayed::Worker.new.run(job)
    assert_in_delta Delayed::Job.db_time_now + 99.minutes, job.reload.run_at, 1
  end
end
