# frozen_string_literal: true

require "test_helper"

class WorkerTest < ActiveSupport::TestCase
  setup do
    @worker = Delayed::Worker.new
    @original_backend = Delayed::Worker.backend
  end

  teardown do
    silence_warnings { Delayed::Worker.backend = @original_backend }
    Delayed::Worker.queues = []
  end

  test "defines delayed_job's defaults" do
    assert_equal "info", Delayed::Worker::DEFAULT_LOG_LEVEL
    assert_equal 5, Delayed::Worker::DEFAULT_SLEEP_DELAY
    assert_equal 25, Delayed::Worker::DEFAULT_MAX_ATTEMPTS
    assert_equal 4.hours, Delayed::Worker::DEFAULT_MAX_RUN_TIME
    assert_equal 0, Delayed::Worker::DEFAULT_DEFAULT_PRIORITY
    assert_equal true, Delayed::Worker::DEFAULT_DELAY_JOBS
    assert_equal [], Delayed::Worker::DEFAULT_QUEUES
    assert_predicate Delayed::Worker::DEFAULT_QUEUES, :frozen?
    assert_equal({}, Delayed::Worker::DEFAULT_QUEUE_ATTRIBUTES)
    assert_kind_of ActiveSupport::HashWithIndifferentAccess, Delayed::Worker::DEFAULT_QUEUE_ATTRIBUTES
    assert_equal 5, Delayed::Worker::DEFAULT_READ_AHEAD
  end

  test "delivery_mode defaults to exactly once" do
    assert_equal :exactly_once, Delayed::Worker::DEFAULT_DELIVERY_MODE
    assert_equal %i[ at_least_once at_most_once exactly_once ], Delayed::Worker::DELIVERY_MODES
    assert_equal :exactly_once, Delayed::Worker.delivery_mode
    assert_equal :exactly_once, @worker.delivery_mode
  end

  test "delivery_mode accepts the three modes as symbols or strings" do
    Delayed::Worker.delivery_mode = :at_least_once
    assert_equal :at_least_once, Delayed::Worker.delivery_mode

    Delayed::Worker.delivery_mode = "at_most_once"
    assert_equal :at_most_once, Delayed::Worker.delivery_mode

    @worker.delivery_mode = :exactly_once
    assert_equal :exactly_once, Delayed::Worker.delivery_mode
  end

  test "delivery_mode rejects anything else" do
    [ :twice, "sometimes", nil, 1 ].each do |mode|
      error = assert_raises(ArgumentError) { Delayed::Worker.delivery_mode = mode }
      assert_equal "Unknown delivery mode #{mode.inspect}. Use :at_least_once, :at_most_once or :exactly_once.", error.message
    end
    assert_equal :exactly_once, Delayed::Worker.delivery_mode
  end

  test "reset restores the defaults" do
    Delayed::Worker.default_log_level = "error"
    Delayed::Worker.sleep_delay = 1
    Delayed::Worker.max_attempts = 2
    Delayed::Worker.max_run_time = 1.minute
    Delayed::Worker.default_priority = 9
    Delayed::Worker.delay_jobs = false
    Delayed::Worker.queues = %w[ a ]
    Delayed::Worker.queue_attributes = { a: { priority: 1 } }
    Delayed::Worker.read_ahead = 50
    Delayed::Worker.delivery_mode = :at_most_once
    lifecycle = Delayed::Worker.lifecycle

    Delayed::Worker.reset

    assert_equal "info", Delayed::Worker.default_log_level
    assert_equal 5, Delayed::Worker.sleep_delay
    assert_equal 25, Delayed::Worker.max_attempts
    assert_equal 4.hours, Delayed::Worker.max_run_time
    assert_equal 0, Delayed::Worker.default_priority
    assert_equal true, Delayed::Worker.delay_jobs
    assert_equal [], Delayed::Worker.queues
    assert_equal({}, Delayed::Worker.queue_attributes)
    assert_equal 5, Delayed::Worker.read_ahead
    assert_equal :exactly_once, Delayed::Worker.delivery_mode
    assert_not_same lifecycle, Delayed::Worker.lifecycle
  end

  test "has every delayed_job setting as a class and instance accessor" do
    %i[ min_priority max_priority max_attempts max_run_time default_priority sleep_delay logger delay_jobs queues
        read_ahead plugins destroy_failed_jobs exit_on_complete default_log_level default_queue_name raise_signal_exceptions delivery_mode ].each do |setting|
      assert_respond_to Delayed::Worker, setting
      assert_respond_to Delayed::Worker, "#{setting}="
      assert_respond_to @worker, setting
      assert_respond_to @worker, "#{setting}="
    end
    assert_respond_to Delayed::Worker, :backend
    assert_respond_to Delayed::Worker, :queue_attributes
  end

  test "instance writers change the class settings" do
    @worker.queues = %w[ large ]
    @worker.max_attempts = 3

    assert_equal %w[ large ], Delayed::Worker.queues
    assert_equal 3, Delayed::Worker.max_attempts
  end

  test "destroy_failed_jobs and raise_signal_exceptions have delayed_job's defaults" do
    assert_equal true, Delayed::Worker.destroy_failed_jobs
    assert_equal false, Delayed::Worker.raise_signal_exceptions
    assert_equal [ Delayed::Plugins::ClearLocks ], @saved_worker_plugins
  end

  test "backend= sets the Delayed::Job constant to the backend" do
    clazz = Class.new
    Delayed::Worker.backend = clazz

    assert_equal clazz, Delayed::Job
    assert_equal clazz, Delayed::Worker.backend
  end

  test "backend= accepts :solid_queue" do
    Delayed::Worker.backend = :solid_queue

    assert_equal Delayed::Backend::SolidQueue::Job, Delayed::Worker.backend
    assert_equal Delayed::Backend::SolidQueue::Job, Delayed::Job
  end

  test "backend= maps delayed_job backends to Solid Queue with a deprecation warning" do
    %i[ active_record mongoid ].each do |backend|
      assert_output(nil, /\[DEPRECATION\] Delayed::Worker.backend = :#{backend} is deprecated/) do
        Delayed::Worker.backend = backend
      end
      assert_equal Delayed::Backend::SolidQueue::Job, Delayed::Worker.backend
    end
  end

  test "backend= rejects unknown backends" do
    error = assert_raises(ArgumentError) { Delayed::Worker.backend = :redis }

    assert_equal "Unknown Delayed::Worker backend :redis. Use :solid_queue.", error.message
  end

  test "queue_attributes= stores indifferent access hashes" do
    Delayed::Worker.queue_attributes = { "mailers" => { priority: 3 } }

    assert_equal 3, Delayed::Worker.queue_attributes[:mailers][:priority]
    assert_equal 3, Delayed::Worker.queue_attributes["mailers"]["priority"]
  end

  test "guess_backend is deprecated" do
    assert_output(nil, "[DEPRECATION] guess_backend is deprecated. Please remove it from your code.\n") do
      Delayed::Worker.guess_backend
    end
  end

  test "before_fork remembers open files and calls the backend" do
    backend = fork_backend(:before_fork)
    Delayed::Worker.backend = backend
    Delayed::Worker.instance_variable_set(:@files_to_reopen, nil)

    Delayed::Worker.before_fork

    assert backend.forked?
    assert_kind_of Array, Delayed::Worker.instance_variable_get(:@files_to_reopen)
  ensure
    Delayed::Worker.instance_variable_set(:@files_to_reopen, nil)
  end

  test "after_fork reopens files, resets Solid Queue connections and calls the backend" do
    path = File.join(TEST_ROOT, "after_fork.log")
    file = File.open(path, "w")
    Delayed::Worker.instance_variable_set(:@files_to_reopen, [ file ])
    backend = fork_backend(:after_fork)
    Delayed::Worker.backend = backend
    SolidQueue.expects(:after_fork!)

    Delayed::Worker.after_fork

    assert backend.forked?
    assert file.sync
  ensure
    file&.close
    Delayed::Worker.instance_variable_set(:@files_to_reopen, nil)
  end

  test "lifecycle is created lazily with the plugins registered" do
    Delayed::Worker.reset

    assert_kind_of Delayed::Lifecycle, Delayed::Worker.lifecycle
    assert_same Delayed::Worker.lifecycle, Delayed::Worker.lifecycle
  end

  test "setup_lifecycle instantiates every plugin" do
    instantiated = []
    plugin = Class.new(Delayed::Plugin) { callbacks { |lifecycle| instantiated << lifecycle } }
    Delayed::Worker.plugins = [ plugin ]

    Delayed::Worker.setup_lifecycle

    assert_equal [ Delayed::Worker.lifecycle ], instantiated
  end

  test "reload_app? follows the Rails reloader settings" do
    Rails.application.config.stubs(:cache_classes).returns(false)
    assert Delayed::Worker.reload_app?

    Rails.application.config.stubs(:cache_classes).returns(true)
    assert_not Delayed::Worker.reload_app?
  end

  test "delay_job? uses delay_jobs as a boolean or a proc" do
    job = Object.new

    Delayed::Worker.delay_jobs = false
    assert_equal false, Delayed::Worker.delay_job?(job)

    Delayed::Worker.delay_jobs = ->(given) { given.equal?(job) }
    assert Delayed::Worker.delay_job?(job)

    Delayed::Worker.delay_jobs = -> { :no_argument }
    assert_equal :no_argument, Delayed::Worker.delay_job?(job)
  end

  test "initialize sets the class settings from the options" do
    Delayed::Worker.new(min_priority: 1, max_priority: 5, sleep_delay: 2, read_ahead: 9, queues: %w[ a b ], exit_on_complete: true)

    assert_equal 1, Delayed::Worker.min_priority
    assert_equal 5, Delayed::Worker.max_priority
    assert_equal 2, Delayed::Worker.sleep_delay
    assert_equal 9, Delayed::Worker.read_ahead
    assert_equal %w[ a b ], Delayed::Worker.queues
    assert_equal true, Delayed::Worker.exit_on_complete
  end

  test "initialize leaves settings that are not given" do
    Delayed::Worker.sleep_delay = 7

    Delayed::Worker.new(queues: %w[ a ])

    assert_equal 7, Delayed::Worker.sleep_delay
  end

  test "initialize resets the lifecycle" do
    lifecycle = Delayed::Worker.lifecycle

    Delayed::Worker.new

    assert_not_same lifecycle, Delayed::Worker.lifecycle
  end

  test "name defaults to the host and pid" do
    assert_equal "host:#{Socket.gethostname} pid:#{Process.pid}", @worker.name
  end

  test "name uses the prefix" do
    @worker.name_prefix = "mailers "

    assert_equal "mailers host:#{Socket.gethostname} pid:#{Process.pid}", @worker.name
  end

  test "name falls back to the pid when the hostname is unavailable" do
    Socket.stubs(:gethostname).raises(SocketError)
    @worker.name_prefix = "x "

    assert_equal "x pid:#{Process.pid}", @worker.name
  end

  test "name can be set and reset" do
    @worker.name = "worker-1"
    assert_equal "worker-1", @worker.name

    @worker.name = nil
    assert_match(/\Ahost:/, @worker.name)
  end

  test "stop and stop?" do
    assert_not @worker.stop?

    @worker.stop

    assert @worker.stop?
  end

  test "job_say logs with job name and id" do
    job = stub(id: 123, name: "ExampleJob", queue: nil)
    @worker.expects(:say).with("Job ExampleJob (id=123) message", Delayed::Worker.default_log_level)

    @worker.job_say(job, "message")
  end

  test "job_say logs with job name, queue and id" do
    job = stub(id: 123, name: "ExampleJob", queue: "test")
    @worker.expects(:say).with("Job ExampleJob (id=123) (queue=test) message", Delayed::Worker.default_log_level)

    @worker.job_say(job, "message")
  end

  test "job_say has a configurable default log level" do
    Delayed::Worker.default_log_level = "error"
    job = stub(id: 123, name: "ExampleJob", queue: nil)
    @worker.expects(:say).with("Job ExampleJob (id=123) message", "error")

    @worker.job_say(job, "message")
  end

  [ [ 0, "debug" ], [ 1, "info" ], [ 2, "warn" ], [ 3, "error" ], [ 4, "fatal" ], [ 5, "unknown" ] ].each do |index, level|
    test "say logs a message on the #{level.upcase} level given a string or an integer" do
      @worker.name = "ExampleJob"
      Delayed::Worker.logger = EnqueueTestHelper::RecordingLogger.new

      freeze_time do
        expected = "#{Time.now.strftime("%FT%T%z")}: [Worker(ExampleJob)] Job executed"
        @worker.say("Job executed", level)
        @worker.say("Job executed", index)

        assert_equal [ [ level, expected ], [ level, expected ] ], Delayed::Worker.logger.messages
      end
    end
  end

  test "say logs on the default log level" do
    Delayed::Worker.logger = EnqueueTestHelper::RecordingLogger.new

    @worker.say("hello")

    assert_equal "info", Delayed::Worker.logger.messages.sole.first
  end

  test "say writes to stdout unless quiet" do
    loud = Delayed::Worker.new(quiet: false)
    loud.name = "loud"

    assert_output("[Worker(loud)] hello\n") { loud.say("hello") }
    assert_output("") { Delayed::Worker.new.say("hello") }
  end

  test "say uses the Solid Queue logger when Delayed::Worker.logger is unset" do
    Delayed::Worker.logger = nil
    logger = EnqueueTestHelper::RecordingLogger.new
    SolidQueue.stubs(:logger).returns(logger)

    @worker.say("hello", "warn")

    assert_equal "warn", logger.messages.sole.first
  end

  test "max_attempts uses the job's value, then the worker's" do
    assert_equal 25, @worker.max_attempts(stub(max_attempts: nil))
    assert_equal 3, @worker.max_attempts(stub(max_attempts: 3))
  end

  test "max_run_time uses the job's value, then the worker's" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    assert_equal Delayed::Worker::DEFAULT_MAX_RUN_TIME, @worker.max_run_time(job)

    job.payload_object.stubs(:max_run_time).returns(45.minutes)
    assert_equal 45.minutes, @worker.max_run_time(job)

    job.payload_object.stubs(:max_run_time).returns(Delayed::Worker::DEFAULT_MAX_RUN_TIME + 60)
    assert_equal Delayed::Worker::DEFAULT_MAX_RUN_TIME, @worker.max_run_time(job)
  end

  test "run invokes the job, removes it and returns true" do
    job = Delayed::Job.enqueue(SimpleJob.new)

    assert_equal true, @worker.run(job)
    assert_equal 1, SimpleJob.runs
    assert_empty queued_jobs
  end

  test "run logs RUNNING and COMPLETED" do
    Delayed::Worker.logger = EnqueueTestHelper::RecordingLogger.new
    job = Delayed::Job.enqueue(NamedJob.new)

    @worker.run(job)

    messages = Delayed::Worker.logger.messages.map(&:last)
    assert(messages.any? { |message| message.end_with?("Job named_job (id=#{job.id}) (queue=default) RUNNING") })
    assert(messages.any? { |message| message.match?(/Job named_job \(id=#{job.id}\) \(queue=default\) COMPLETED after \d+\.\d{4}\z/) })
  end

  test "run fails after Worker.max_run_time" do
    Delayed::Worker.max_run_time = 1.second
    job = Delayed::Job.enqueue(LongRunningJob.new)

    assert_equal false, @worker.run(job)

    assert_not_nil job.error
    assert_match(/expired/, job.last_error)
    assert_match(/Delayed::Worker\.max_run_time is only 1 second/, job.last_error)
    assert_equal 1, job.attempts
  end

  test "run records last_error when destroy_failed_jobs is false and max_attempts is 1" do
    Delayed::Worker.destroy_failed_jobs = false
    Delayed::Worker.max_attempts = 1
    job = Delayed::Job.enqueue(ErrorJob.new, run_at: 1.second.ago)

    @worker.run(job)

    assert_not_nil job.error
    assert_match(/did not work/, job.last_error)
    assert_equal 1, job.attempts
    assert job.failed?
    job.reload
    assert job.failed?
    assert_match(/did not work/, job.last_error)
    assert_equal 1, job.attempts
    assert_equal [ job.active_job_id ], solid_queue_jobs(:failed).map(&:active_job_id)
  end

  test "run re-schedules jobs after failing" do
    job = Delayed::Job.enqueue(ErrorJob.new, run_at: 1.second.ago)

    @worker.run(job)

    assert_match(/did not work/, job.last_error)
    assert_match(/sample_jobs.rb:\d+:in '(ErrorJob#)?perform'/, job.last_error)
    assert_equal 1, job.attempts
    assert_operator job.run_at, :>, 10.minutes.ago
    assert_operator job.run_at, :<, 10.minutes.from_now
    assert_nil job.locked_by
    assert_nil job.locked_at
    job.reload
    assert_match(/did not work/, job.last_error)
    assert_equal 1, job.attempts
    assert_operator job.run_at, :>, 10.minutes.ago
    assert_operator job.run_at, :<, 10.minutes.from_now
    assert_nil job.locked_by
    assert_nil job.locked_at
    assert_equal [ job.active_job_id ], queued_jobs.map(&:active_job_id)
  end

  test "run re-schedules jobs with handler provided time if present" do
    job = Delayed::Job.enqueue(CustomRescheduleJob.new(99.minutes))

    @worker.run(job)

    assert_in_delta 99.minutes.from_now, job.run_at, 1
    assert_in_delta 99.minutes.from_now, job.reload.run_at, 1
  end

  test "run does not fail when the triggered error doesn't have a message" do
    job = Delayed::Job.enqueue(ErrorJob.new)
    error_with_nil_message = StandardError.new
    error_with_nil_message.stubs(:message).returns(nil)
    job.expects(:invoke_job).raises(error_with_nil_message)

    assert_nothing_raised { @worker.run(job) }
  end

  test "run marks jobs that raise DeserializationError as failed" do
    Delayed::Worker.destroy_failed_jobs = false
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.stubs(:invoke_job).raises(Delayed::DeserializationError, "gone")

    @worker.run(job)

    assert job.failed?
    assert job.reload.failed?
    assert_equal "Delayed::DeserializationError", failed_job_error(job)[:exception_class]
  end

  test "run runs the error lifecycle around the failure handling" do
    events = []
    Delayed::Worker.lifecycle.around(:error) do |worker, job, &block|
      events << [ worker, job.class ]
      block.call(worker, job)
    end
    job = Delayed::Job.enqueue(ErrorJob.new)

    @worker.run(job)

    assert_equal [ [ @worker, Delayed::Job ] ], events
  end

  test "run publishes timeout.delayed_job" do
    Delayed::Worker.max_run_time = 1.second
    job = Delayed::Job.enqueue(LongRunningJob.new)

    events = capture_delayed_job_events { @worker.run(job) }

    timeout = events.find { |event| event.name == "timeout.delayed_job" }
    assert_equal job.active_job_id, timeout.payload[:job_id]
    assert_equal 1.second, timeout.payload[:max_run_time]
  end

  test "reschedule is not destroyed if failed fewer than max_attempts times" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.expects(:destroy).never

    (Delayed::Worker.max_attempts - 1).times { @worker.reschedule(job) }

    assert_equal 24, job.attempts
    assert_equal 1, queued_jobs.size
  end

  test "reschedule destroys the job after max_attempts" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.expects(:destroy)

    Delayed::Worker.max_attempts.times { @worker.reschedule(job) }
  end

  test "reschedule destroys the job when the job has destroy_failed_jobs set" do
    Delayed::Worker.destroy_failed_jobs = false
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.expects(:destroy_failed_jobs?).returns(true)
    job.expects(:destroy)

    Delayed::Worker.max_attempts.times { @worker.reschedule(job) }
  end

  test "reschedule fails the job after max_attempts when destroy_failed_jobs is false" do
    Delayed::Worker.destroy_failed_jobs = false
    job = Delayed::Job.enqueue(SimpleJob.new)

    (Delayed::Worker.max_attempts - 1).times { @worker.reschedule(job) }
    assert_not job.failed?
    assert_empty solid_queue_jobs(:failed)

    @worker.reschedule(job)
    assert job.failed?
    assert job.reload.failed?
    assert_equal Delayed::Worker.max_attempts, job.attempts
    assert_empty queued_jobs
  end

  test "reschedule fails the job when the job's destroy_failed_jobs? is false" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.expects(:destroy_failed_jobs?).returns(false)

    Delayed::Worker.max_attempts.times { @worker.reschedule(job) }

    assert job.failed?
    assert job.reload.failed?
  end

  test "reschedule runs the payload's failure hook" do
    job = Delayed::Job.enqueue(OnPermanentFailureJob.new)
    job.payload_object.expects(:failure)

    @worker.reschedule(job)
  end

  test "reschedule handles an error in the failure hook" do
    Delayed::Worker.destroy_failed_jobs = false
    job = Delayed::Job.enqueue(FailingFailureHookJob.new)

    assert_nothing_raised { @worker.reschedule(job) }
    assert_not_nil job.failed_at
  end

  test "reschedule does not call a missing failure hook" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    assert_not job.payload_object.respond_to?(:failure)

    assert_nothing_raised { Delayed::Worker.max_attempts.times { @worker.reschedule(job) } }
  end

  test "reschedule uses the given time" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    later = 3.hours.from_now.change(usec: 0)

    @worker.reschedule(job, later)

    assert_equal later, job.run_at
    assert_in_delta later, job.reload.run_at, 1
  end

  test "failed runs the failure lifecycle and publishes failure.delayed_job" do
    events = []
    Delayed::Worker.lifecycle.before(:failure) { |worker, job| events << [ worker, job.class ] }
    job = Delayed::Job.enqueue(SimpleJob.new)

    notifications = capture_delayed_job_events { @worker.failed(job) }

    assert_equal [ [ @worker, Delayed::Job ] ], events
    assert_equal [ "failure.delayed_job" ], notifications.map(&:name)
    assert_empty queued_jobs
  end

  test "work_off runs jobs and returns successes and failures" do
    Delayed::Job.enqueue SimpleJob.new
    Delayed::Job.enqueue SimpleJob.new
    Delayed::Job.enqueue ErrorJob.new

    assert_equal [ 2, 1 ], @worker.work_off
    assert_equal 2, SimpleJob.runs
    assert_equal 1, solid_queue_jobs(:scheduled).size
  end

  test "work_off counts failures kept in Solid Queue" do
    Delayed::Worker.destroy_failed_jobs = false
    Delayed::Worker.max_attempts = 1
    Delayed::Job.enqueue ErrorJob.new

    assert_equal [ 0, 1 ], @worker.work_off
    assert_equal 1, solid_queue_jobs(:failed).size
  end

  test "work_off stops after num jobs" do
    3.times { Delayed::Job.enqueue SimpleJob.new }

    assert_equal [ 2, 0 ], @worker.work_off(2)
    assert_equal 1, queued_jobs.size
  end

  test "work_off runs due scheduled jobs and leaves future ones" do
    Delayed::Job.enqueue SimpleJob.new, run_at: 1.minute.ago
    Delayed::Job.enqueue SimpleJob.new, run_at: 1.hour.from_now

    assert_equal [ 1, 0 ], @worker.work_off
    assert_equal 1, solid_queue_jobs(:scheduled).size
  end

  test "work_off only works off jobs from the worker's queue" do
    @worker.queues = [ "large" ]
    Delayed::Job.enqueue SimpleJob.new, queue: "large"
    Delayed::Job.enqueue SimpleJob.new, queue: "small"

    @worker.work_off

    assert_equal 1, SimpleJob.runs
  end

  test "work_off only works off jobs from the worker's queues" do
    @worker.queues = %w[ large small ]
    Delayed::Job.enqueue SimpleJob.new, queue: "large"
    Delayed::Job.enqueue SimpleJob.new, queue: "small"
    Delayed::Job.enqueue SimpleJob.new, queue: "medium"
    Delayed::Job.enqueue SimpleJob.new

    @worker.work_off

    assert_equal 2, SimpleJob.runs
  end

  test "work_off works off all jobs when no queues are set" do
    @worker.queues = []
    Delayed::Job.enqueue SimpleJob.new, queue: "one"
    Delayed::Job.enqueue SimpleJob.new, queue: "two"
    Delayed::Job.enqueue SimpleJob.new

    @worker.work_off

    assert_equal 3, SimpleJob.runs
  end

  test "work_off only finds jobs within the priority range" do
    Delayed::Worker.min_priority = 5
    Delayed::Worker.max_priority = 6
    [ 4, 5, 6, 7 ].each { |priority| Delayed::Job.enqueue SimpleJob.new, priority: priority }

    assert_equal [ 2, 0 ], @worker.work_off
    assert_equal [ 4, 7 ], queued_jobs.map(&:priority).sort
  end

  test "work_off runs jobs in priority order" do
    StatefulJob.performed = []
    [ 3, 1, 2 ].each { |priority| Delayed::Job.enqueue StatefulJob.new("p", priority), priority: priority }

    @worker.work_off

    assert_equal [ 1, 2, 3 ], StatefulJob.performed.map(&:second)
  end

  test "work_off runs the perform lifecycle with this worker" do
    workers = []
    Delayed::Worker.lifecycle.before(:perform) { |worker, _job| workers << worker }
    Delayed::Job.enqueue SimpleJob.new

    @worker.work_off

    assert_equal [ @worker ], workers
  end

  test "work_off hands the queues, limit and priority range to SolidQueue.work_off" do
    Delayed::Worker.queues = %w[ mailers ]
    Delayed::Worker.min_priority = 2
    Delayed::Worker.max_priority = 8
    SolidQueue.expects(:work_off).with(queues: %w[ mailers ], limit: 7, priority: 2..8).returns(SolidQueue::WorkOff::Result.new(3, 1))

    assert_equal [ 3, 1 ], @worker.work_off(7)
  end

  test "work_off passes an open-ended priority range and all queues" do
    Delayed::Worker.max_priority = 4
    SolidQueue.expects(:work_off).with(queues: [ "*" ], limit: 100, priority: nil..4).returns(SolidQueue::WorkOff::Result.new(0, 0))

    @worker.work_off
  end

  test "work_off handles errors while reserving jobs" do
    SolidQueue.stubs(:work_off).raises(RuntimeError, "database down")

    assert_equal [ 0, 0 ], @worker.work_off
  end

  test "work_off gives up after 10 backend failures" do
    SolidQueue.expects(:work_off).times(10).raises(RuntimeError, "database down")

    9.times { @worker.work_off }
    assert_raises(Delayed::FatalBackendError) { @worker.work_off }
  end

  test "work_off lets the backend attempt recovery from reservation errors" do
    backend = Class.new do
      class << self
        attr_reader :recovered

        def recover_from(error)
          @recovered = error
        end
      end
    end
    Delayed::Worker.backend = backend
    SolidQueue.stubs(:work_off).raises(RuntimeError, "database down")

    @worker.work_off

    assert_equal "database down", backend.recovered.message
  end

  test "work_off stops early when the worker is stopping" do
    3.times { Delayed::Job.enqueue SimpleJob.new }
    @worker.stop

    assert_equal [ 1, 0 ], @worker.work_off
  end

  test "Delayed::Job.work_off-style calls use Delayed::Worker.current inside the job" do
    seen = nil
    Delayed::Worker.lifecycle.before(:perform) { |worker, _job| seen = worker }
    Delayed::Job.enqueue SimpleJob.new

    perform_ready_jobs

    assert_same Delayed::Worker.current, seen
    assert_kind_of Delayed::Worker, seen
  end

  test "start exits when no jobs are available and exit_on_complete is set" do
    Delayed::Worker.exit_on_complete = true
    Delayed::Worker.sleep_delay = 0.1
    Delayed::Worker.logger = EnqueueTestHelper::RecordingLogger.new
    Delayed::Job.enqueue SimpleJob.new

    Timeout.timeout(10) { Delayed::Worker.new.start }

    assert_equal 1, SimpleJob.runs
    assert_empty queued_jobs
    messages = Delayed::Worker.logger.messages.map(&:last)
    assert(messages.any? { |message| message.end_with?("Starting job worker") })
    assert(messages.any? { |message| message.end_with?("No more jobs available. Exiting") })
  end

  test "start runs jobs once their run_at comes, including retries" do
    Delayed::Worker.sleep_delay = 0.1
    Delayed::Worker.max_attempts = 2
    worker = Delayed::Worker.new
    runs = 0
    Delayed::Worker.lifecycle.before(:perform) { |_worker, job| runs += 1 if job.name == "CustomRescheduleJob" }
    Delayed::Job.enqueue SimpleJob.new, run_at: 1.second.from_now
    Delayed::Job.enqueue CustomRescheduleJob.new(1.second)
    runner = Thread.new { worker.start }

    Timeout.timeout(15) { sleep 0.05 until SimpleJob.runs == 1 && runs == 2 }
    worker.stop
    assert runner.join(10)

    assert_empty queued_jobs
    assert_empty SolidQueue::Admin.processes(kind: "Dispatcher")
  end

  test "start with exit_on_complete leaves jobs that are not due yet" do
    Delayed::Worker.exit_on_complete = true
    Delayed::Worker.sleep_delay = 0.1
    Delayed::Job.enqueue SimpleJob.new, run_at: 1.hour.from_now

    Timeout.timeout(10) { Delayed::Worker.new.start }

    assert_equal 0, SimpleJob.runs
    assert_equal 1, solid_queue_jobs(:scheduled).size
  end

  test "start runs the execute lifecycle with the worker" do
    Delayed::Worker.exit_on_complete = true
    Delayed::Worker.sleep_delay = 0.1
    worker = Delayed::Worker.new
    executed = nil
    Delayed::Worker.lifecycle.around(:execute) do |w, &block|
      executed = w
      block.call(w)
    end

    Timeout.timeout(10) { worker.start }

    assert_same worker, executed
  end

  test "start runs a Solid Queue worker with the delayed_job settings" do
    Delayed::Worker.queues = %w[ mailers default ]
    Delayed::Worker.sleep_delay = 2
    Delayed::Worker.min_priority = 1
    Delayed::Worker.max_priority = 9
    Delayed::Worker.exit_on_complete = true
    process = SolidQueue::Worker.new(queues: "*", polling_interval: 1)
    SolidQueue::Worker.expects(:new).with(queues: %w[ mailers default ], polling_interval: 2, threads: 1, min_priority: 1, max_priority: 9, exit_on_complete: true).returns(process)
    process.expects(:start)
    process.stubs(:alive?).returns(false)
    process.expects(:stop)

    Delayed::Worker.new.start
  end

  test "start maps empty queues to all queues and leaves unset options out" do
    process = SolidQueue::Worker.new(queues: "*", polling_interval: 1)
    SolidQueue::Worker.expects(:new).with(queues: [ "*" ], polling_interval: 5, threads: 1).returns(process)
    process.stubs(:start)
    process.stubs(:alive?).returns(false)
    process.stubs(:stop)

    Delayed::Worker.new.start
  end

  test "start stops the Solid Queue worker when the worker is stopped" do
    worker = Delayed::Worker.new
    Delayed::Worker.sleep_delay = 0.1
    Delayed::Job.enqueue SimpleJob.new
    runner = Thread.new { worker.start }

    Timeout.timeout(10) { sleep 0.05 until SimpleJob.runs == 1 }
    worker.stop
    assert runner.join(10)
    assert_empty SolidQueue::Admin.processes
    assert_empty SolidQueue::Admin.processes(kind: "Dispatcher")
  end

  test "start runs the loop lifecycle around Solid Queue polls" do
    Delayed::Worker.exit_on_complete = true
    Delayed::Worker.sleep_delay = 0.1
    worker = Delayed::Worker.new
    loops = []
    Delayed::Worker.lifecycle.before(:loop) { |w| loops << w }

    Timeout.timeout(10) { worker.start }

    assert_operator loops.size, :>=, 1
    assert(loops.all? { |w| w.equal?(worker) })
  end

  test "the loop lifecycle hook comes back after Solid Queue hooks are cleared" do
    SolidQueue::ExecutionHooks.clear
    assert_not SolidQueue::ExecutionHooks.registered?(:around_poll)

    worker = Delayed::Worker.new
    Delayed::Worker.new
    loops = []
    Delayed::Worker.lifecycle.before(:loop) { |w| loops << w }
    Delayed::Worker.send(:running=, worker)
    result = SolidQueue::ExecutionHooks.run(:around_poll, SolidQueue::Worker.new(queues: "*", polling_interval: 1)) { :polled }

    assert_equal :polled, result
    assert_equal [ worker ], loops
  ensure
    Delayed::Worker.send(:running=, nil)
  end

  test "start traps TERM and INT to stop the worker and restores the previous handlers" do
    Delayed::Worker.exit_on_complete = true
    Delayed::Worker.sleep_delay = 0.1
    worker = Delayed::Worker.new
    previous = trap("TERM", "DEFAULT")
    handlers = {}
    Delayed::Worker.lifecycle.before(:execute) do
      handlers["TERM"] = trap("TERM", "DEFAULT").tap { |handler| trap("TERM", handler) }
      handlers["INT"] = trap("INT", "DEFAULT").tap { |handler| trap("INT", handler) }
    end

    Timeout.timeout(10) { worker.start }

    assert_kind_of Proc, handlers["TERM"]
    assert_kind_of Proc, handlers["INT"]
    capture_io { handlers["TERM"].call }
    assert worker.stop?
    assert_equal "DEFAULT", trap("TERM", previous)
  end

  test "signal handlers raise SignalException according to raise_signal_exceptions" do
    worker = Delayed::Worker.new
    handlers = nil
    worker.stubs(:run_solid_queue_worker)
    Delayed::Worker.lifecycle.before(:execute) do
      handlers = %w[ TERM INT ].to_h { |signal| [ signal, trap(signal, "DEFAULT").tap { |handler| trap(signal, handler) } ] }
    end
    worker.start

    Delayed::Worker.raise_signal_exceptions = false
    capture_io { handlers.each_value(&:call) }

    Delayed::Worker.raise_signal_exceptions = :term
    assert_raises(SignalException) { capture_io { handlers["TERM"].call } }
    capture_io { handlers["INT"].call }

    Delayed::Worker.raise_signal_exceptions = true
    assert_raises(SignalException) { capture_io { handlers["INT"].call } }
  end

  private
    def fork_backend(hook)
      Class.new do
        singleton_class.define_method(hook) { @forked = true }
        singleton_class.define_method(:forked?) { @forked }
      end
    end
end
