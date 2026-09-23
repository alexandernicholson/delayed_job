# frozen_string_literal: true

require "test_helper"

class RetryPolicyTest < ActiveSupport::TestCase
  setup do
    KeptFailureJob.failures = 0
  end

  test "the default back-off is attempts to the fourth plus five seconds" do
    now = Time.current

    assert_equal now + 6, Delayed::RetryPolicy.default_reschedule_at(now, 1)
    assert_equal now + 21, Delayed::RetryPolicy.default_reschedule_at(now, 2)
    assert_equal now + 630, Delayed::RetryPolicy.default_reschedule_at(now, 5)
  end

  test "reschedule_at uses the default back-off from the job's attempts" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.attempts = 2

    freeze_time { assert_equal Time.current + 21, job.reschedule_at }
  end

  test "reschedule_at uses the payload's reschedule_at with the time and attempts" do
    job = Delayed::Job.enqueue(CustomRescheduleJob.new(99.minutes))
    job.attempts = 3
    job.payload_object.expects(:reschedule_at).with(instance_of(ActiveSupport::TimeWithZone), 3).returns(:later)

    assert_equal :later, job.reschedule_at
  end

  test "max_attempts is not defined unless the payload defines it" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    assert_nil job.max_attempts

    job.payload_object.expects(:max_attempts).returns(99)
    assert_equal 99, job.max_attempts
  end

  test "max_run_time is not defined unless the payload defines it" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    assert_nil job.max_run_time

    job.payload_object.stubs(:max_run_time).returns(30.minutes)
    assert_equal 30.minutes, job.max_run_time
  end

  test "max_run_time can not exceed Delayed::Worker.max_run_time" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.payload_object.stubs(:max_run_time).returns(Delayed::Worker::DEFAULT_MAX_RUN_TIME + 60)

    assert_equal Delayed::Worker::DEFAULT_MAX_RUN_TIME, job.max_run_time
  end

  test "max_run_time is nil when the payload returns nil" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.payload_object.stubs(:max_run_time).returns(nil)

    assert_nil job.max_run_time
  end

  test "destroy_failed_jobs? defaults to Delayed::Worker.destroy_failed_jobs" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    assert_equal true, job.destroy_failed_jobs?

    Delayed::Worker.destroy_failed_jobs = false
    assert_equal false, job.destroy_failed_jobs?
  end

  test "destroy_failed_jobs? uses the payload value when defined" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.payload_object.expects(:destroy_failed_jobs?).returns(false)

    assert_equal false, job.destroy_failed_jobs?
  end

  test "destroy_failed_jobs? falls back when the payload cannot be loaded" do
    story = Story.create(text: "hello")
    job = story.delay.tell
    story.destroy

    assert_equal true, ActiveJob::Base.deserialize(serialized_job(job.job_id)).destroy_failed_jobs?
  end

  test "a failing job is rescheduled with the default back-off" do
    job = Delayed::Job.enqueue(ErrorJob.new)

    freeze_time do
      perform_ready_jobs

      rescheduled = solid_queue_jobs(:scheduled)
      assert_equal [ job.job_id ], rescheduled.map(&:active_job_id)
      assert_in_delta Time.current + 6, rescheduled.first.scheduled_at, 1
      assert_equal 1, rescheduled.first.arguments["executions"]
      assert_equal 1, ActiveJob::Base.deserialize(rescheduled.first.arguments).attempts
    end
    assert_empty solid_queue_jobs(:failed)
  end

  test "each failure increases attempts and the back-off" do
    job = Delayed::Job.enqueue(ErrorJob.new)
    perform_ready_jobs
    perform_due_jobs(at: 1.minute.from_now)

    travel_to(1.minute.from_now) do
      rescheduled = solid_queue_jobs(:scheduled).sole
      assert_equal job.job_id, rescheduled.active_job_id
      assert_equal 2, rescheduled.arguments["executions"]
      assert_in_delta Time.current + 21, rescheduled.scheduled_at, 2
    end
  end

  test "a failing job with a custom reschedule_at is rescheduled at that time" do
    Delayed::Job.enqueue(CustomRescheduleJob.new(99.minutes))

    freeze_time do
      perform_ready_jobs

      assert_in_delta Time.current + 99.minutes, solid_queue_jobs(:scheduled).sole.scheduled_at, 1
    end
  end

  test "a rescheduled job keeps its queue and priority" do
    Delayed::Job.enqueue(ErrorJob.new, queue: "retries", priority: 7)

    perform_ready_jobs

    rescheduled = solid_queue_jobs(:scheduled).sole
    assert_equal "retries", rescheduled.queue_name
    assert_equal 7, rescheduled.priority
  end

  test "publishes retry.delayed_job when a job is rescheduled" do
    job = Delayed::Job.enqueue(ErrorJob.new)

    events = capture_delayed_job_events { perform_ready_jobs }

    retry_event = events.find { |event| event.name == "retry.delayed_job" }
    assert_equal job.job_id, retry_event.payload[:job_id]
    assert_equal 1, retry_event.payload[:attempts]
    assert_equal false, events.find { |event| event.name == "perform.delayed_job" }.payload[:success]
  end

  test "a job is removed after Delayed::Worker.max_attempts failures" do
    Delayed::Worker.max_attempts = 2
    Delayed::Job.enqueue(ErrorJob.new)

    perform_ready_jobs
    assert_equal 1, solid_queue_jobs(:scheduled).size

    perform_due_jobs(at: 1.minute.from_now)
    assert_empty queued_jobs
    assert_empty solid_queue_jobs(:failed)
  end

  test "the payload's max_attempts wins over Delayed::Worker.max_attempts" do
    Delayed::Job.enqueue(TwoAttemptJob.new)

    perform_ready_jobs
    assert_equal 1, solid_queue_jobs(:scheduled).size

    perform_due_jobs(at: 1.minute.from_now)
    assert_empty queued_jobs
  end

  test "exhausted jobs run the failure hook and are kept when destroy_failed_jobs is false" do
    Delayed::Worker.destroy_failed_jobs = false
    Delayed::Worker.max_attempts = 1
    job = Delayed::Job.enqueue(FailingCallbackJob.new)

    perform_ready_jobs

    assert_equal [ "enqueue", "before", "error: RuntimeError", "after", "failure" ], CallbackJob.messages
    failed = solid_queue_jobs(:failed)
    assert_equal [ job.job_id ], failed.map(&:active_job_id)
    assert_equal "did not work", failed_job_error(job.job_id)[:message]
    assert_equal "RuntimeError", failed_job_error(job.job_id)[:exception_class]
    assert_empty queued_jobs
  end

  test "exhausted jobs are removed when destroy_failed_jobs is true" do
    Delayed::Worker.max_attempts = 1
    Delayed::Job.enqueue(ErrorJob.new)

    perform_ready_jobs

    assert_empty queued_jobs
    assert_empty solid_queue_jobs(:failed)
  end

  test "the payload's destroy_failed_jobs? keeps failed jobs" do
    job = Delayed::Job.enqueue(KeptFailureJob.new)

    perform_ready_jobs

    assert_equal 1, KeptFailureJob.failures
    assert_equal [ job.job_id ], solid_queue_jobs(:failed).map(&:active_job_id)
  end

  test "the payload's destroy_failed_jobs? removes failed jobs" do
    Delayed::Worker.destroy_failed_jobs = false
    Delayed::Job.enqueue(DestroyedFailureJob.new)

    perform_ready_jobs

    assert_equal 1, DestroyedFailureJob.failures
    assert_empty solid_queue_jobs(:failed)
    assert_empty queued_jobs
  end

  test "an error in the failure hook is logged and the job is still failed" do
    Delayed::Worker.destroy_failed_jobs = false
    Delayed::Worker.logger = EnqueueTestHelper::RecordingLogger.new
    job = Delayed::Job.enqueue(FailingFailureHookJob.new)

    perform_ready_jobs

    assert_equal [ job.job_id ], solid_queue_jobs(:failed).map(&:active_job_id)
    assert(Delayed::Worker.logger.messages.any? { |level, message| level == "error" && message.include?("Error when running failure callback: failure hook broke") })
  end

  test "fail! during an attempt without an error records a generic failure in Solid Queue" do
    Delayed::Worker.lifecycle.around(:perform) do |_worker, job|
      job.fail!
      true
    end
    job = Delayed::Job.enqueue(SimpleJob.new)

    perform_ready_jobs

    assert_equal 0, SimpleJob.runs
    assert_equal "RuntimeError", failed_job_error(job.job_id)[:exception_class]
    assert_equal "SimpleJob failed", failed_job_error(job.job_id)[:message]
  end

  test "publishes failure.delayed_job when retries are exhausted" do
    Delayed::Worker.max_attempts = 1
    job = Delayed::Job.enqueue(ErrorJob.new)

    events = capture_delayed_job_events { perform_ready_jobs }

    failure = events.find { |event| event.name == "failure.delayed_job" }
    assert_equal job.job_id, failure.payload[:job_id]
    assert_equal 1, failure.payload[:attempts]
  end

  test "jobs that exceed Delayed::Worker.max_run_time fail with WorkerTimeout" do
    Delayed::Worker.max_run_time = 1.second
    Delayed::Worker.max_attempts = 1
    Delayed::Worker.destroy_failed_jobs = false
    job = Delayed::Job.enqueue(LongRunningJob.new)

    events = capture_delayed_job_events { perform_ready_jobs }

    error = failed_job_error(job.job_id)
    assert_equal "Delayed::WorkerTimeout", error[:exception_class]
    assert_match(/expired/, error[:message])
    assert_match(/Delayed::Worker\.max_run_time is only 1 second/, error[:message])
    assert(events.any? { |event| event.name == "timeout.delayed_job" && event.payload[:job_id] == job.job_id })
  end

  test "jobs that exceed their own max_run_time time out" do
    Delayed::Worker.max_attempts = 1
    Delayed::Worker.destroy_failed_jobs = false
    job = Delayed::Job.enqueue(ShortRunTimeJob.new)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    perform_ready_jobs

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 4
    assert_equal "Delayed::WorkerTimeout", failed_job_error(job.job_id)[:exception_class]
  end

  test "a timed out job is rescheduled like any failure" do
    Delayed::Worker.max_run_time = 1.second
    job = Delayed::Job.enqueue(LongRunningJob.new)

    perform_ready_jobs

    assert_equal [ job.job_id ], solid_queue_jobs(:scheduled).map(&:active_job_id)
  end

  test "jobs whose payload cannot be loaded fail permanently" do
    Delayed::Worker.destroy_failed_jobs = false
    story = Story.create(text: "hello")
    job = story.delay.tell
    story.destroy

    perform_ready_jobs

    assert_empty queued_jobs
    error = failed_job_error(job.job_id)
    assert_equal "Delayed::DeserializationError", error[:exception_class]
    assert_match(/\AJob failed to load: /, error[:message])
  end

  test "jobs whose payload cannot be loaded are removed when destroy_failed_jobs is true" do
    story = Story.create(text: "hello")
    story.delay.tell
    story.destroy

    perform_ready_jobs

    assert_empty queued_jobs
    assert_empty solid_queue_jobs(:failed)
  end

  test "runs the perform, error and failure lifecycle events with the worker and job" do
    Delayed::Worker.max_attempts = 1
    events = []
    %i[ perform error failure ].each do |event|
      Delayed::Worker.lifecycle.before(event) { |worker, job| events << [ event, worker.class, job.class ] }
    end
    Delayed::Job.enqueue(ErrorJob.new)

    perform_ready_jobs

    assert_equal [ [ :perform, Delayed::Worker, Delayed::JobWrapper ], [ :error, Delayed::Worker, Delayed::JobWrapper ], [ :failure, Delayed::Worker, Delayed::JobWrapper ] ], events
  end

  test "Delayed::Worker.max_run_time limits Delayed::JobWrapper jobs only" do
    Delayed::Worker.max_run_time = 1.hour

    assert_equal 1.hour, Delayed::JobWrapper.run_time_limit
    assert_nil SolidQueue.max_run_time
    assert_nil PlainActiveJob.run_time_limit
    assert_nil ActiveJob::Base.run_time_limit

    wrapped = Delayed::Job.enqueue(SimpleJob.new)
    plain = PlainActiveJob.perform_later
    assert_equal 1.hour, solid_queue_job(wrapped.job_id).run_time_limit
    assert_nil solid_queue_job(plain.job_id).run_time_limit
  end

  test "reset restores the Delayed::JobWrapper run-time limit" do
    Delayed::Worker.max_run_time = 1.hour

    Delayed::Worker.reset

    assert_equal Delayed::Worker::DEFAULT_MAX_RUN_TIME, Delayed::JobWrapper.run_time_limit
  end

  test "a max_run_time that is not a positive duration removes the Delayed::JobWrapper run-time limit" do
    [ 0, -1, nil ].each do |run_time|
      Delayed::Worker.max_run_time = run_time

      assert_nil Delayed::JobWrapper.run_time_limit
    end
  end

  test "Delayed::Worker.max_attempts leaves Solid Queue death recovery alone for other jobs" do
    Delayed::Worker.max_attempts = 7

    assert_nil SolidQueue.retry_on_process_death
    assert_nil PlainActiveJob.try(:process_death_attempts)
  end

  test "Delayed::Worker.max_attempts caps death retries for Delayed::JobWrapper jobs" do
    skip "needs Solid Queue per-job death retries" unless Delayed::JobWrapper.respond_to?(:retries_on_process_death)

    Delayed::Worker.max_attempts = 7
    assert_equal 7, Delayed::JobWrapper.process_death_attempts

    Delayed::Worker.reset
    assert_equal Delayed::Worker::DEFAULT_MAX_ATTEMPTS, Delayed::JobWrapper.process_death_attempts
  end

  test "the Delayed::JobWrapper limits are in place when the app boots" do
    script = <<~RUBY
      require "test_helper"
      values = [ Delayed::JobWrapper.run_time_limit.to_i, PlainActiveJob.run_time_limit.inspect, SolidQueue.max_run_time.inspect,
        SolidQueue.retry_on_process_death.inspect, Delayed::JobWrapper.try(:process_death_attempts).inspect ]
      puts "limits=\#{values.join(",")}"
      $stdout.flush
      FileUtils.remove_entry(TEST_ROOT)
      exit!(0)
    RUBY

    output = IO.popen([ RbConfig.ruby, "-I", __dir__, "-I", File.expand_path("../lib", __dir__), "-e", script ], err: File::NULL, &:read)

    death_attempts = Delayed::JobWrapper.respond_to?(:retries_on_process_death) ? "25" : "nil"
    assert_includes output, "limits=#{4.hours.to_i},nil,nil,nil,#{death_attempts}"
  end

  test "per-job death retries added by Solid Queue at boot are applied to Delayed::JobWrapper" do
    script = <<~RUBY
      require "rails"
      class StandInDeathRetries < Rails::Railtie
        initializer "stand_in.death_retries" do
          ActiveSupport.on_load(:active_job) do
            unless respond_to?(:retries_on_process_death)
              class_attribute :process_death_attempts, instance_accessor: false
              define_singleton_method(:retries_on_process_death) { |attempts:| self.process_death_attempts = attempts }
            end
          end
        end
      end
      require "test_helper"
      puts "attempts=\#{Delayed::JobWrapper.process_death_attempts.inspect},\#{PlainActiveJob.process_death_attempts.inspect}"
      $stdout.flush
      FileUtils.remove_entry(TEST_ROOT)
      exit!(0)
    RUBY

    output = IO.popen([ RbConfig.ruby, "-I", __dir__, "-I", File.expand_path("../lib", __dir__), "-e", script ], err: File::NULL, &:read)

    assert_includes output, "attempts=25,nil"
  end

  test "jobs claimed by a process that died are re-run" do
    skip "needs Solid Queue per-job death retries" unless Delayed::JobWrapper.respond_to?(:retries_on_process_death)

    job = Delayed::Job.enqueue(SimpleJob.new)
    process = register_test_process
    SolidQueue::ReadyExecution.claim("*", 1, process.id)
    SolidQueue::ClaimedExecution.fail_all_with(SolidQueue::Processes::ProcessPrunedError.new(process.last_heartbeat_at))

    assert_equal [ job.job_id ], solid_queue_jobs(:pending).map(&:active_job_id)
    perform_ready_jobs
    assert_equal 1, SimpleJob.runs
  ensure
    process&.deregister
  end
end
