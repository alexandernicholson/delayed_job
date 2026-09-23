# frozen_string_literal: true

require "test_helper"

class JobWrapperTest < ActiveSupport::TestCase
  Notifier = Struct.new(:delivery_mode) do
    cattr_accessor :sent, default: []

    def notify
      sent << delivery_mode
    end
  end

  setup do
    Delayed::Worker.default_priority = 99
    Delayed::Worker.default_queue_name = "default_tracking"
    M::ModuleJob.runs = 0
    ZeroArityHookJob.messages = []
    Notifier.sent = []
  end

  test "is the Active Job class that carries every payload" do
    assert_operator Delayed::JobWrapper, :<, ActiveJob::Base
    assert_includes Delayed::JobWrapper.ancestors, Delayed::RetryPolicy
  end

  test "enqueue_payload stores the payload in Solid Queue and returns the job" do
    payload = SimpleJob.new
    run_at = 5.minutes.from_now

    job = Delayed::JobWrapper.enqueue_payload(payload, queue: "tracking", priority: 3, run_at: run_at)

    assert_instance_of Delayed::JobWrapper, job
    assert_same payload, job.payload_object
    assert_equal "tracking", job.queue
    assert_equal 3, job.priority
    assert_equal run_at, job.run_at
    assert_equal 0, job.attempts
    assert_equal job.provider_job_id, job.id

    stored = solid_queue_job(job.job_id)
    assert_equal "Delayed::JobWrapper", stored.class_name
    assert_equal "tracking", stored.queue_name
    assert_equal 3, stored.priority
    assert_equal [ job.job_id ], solid_queue_jobs(:scheduled).map(&:active_job_id)
  end

  test "enqueue_payload keeps attempts and job_id from the options" do
    job = Delayed::JobWrapper.enqueue_payload(SimpleJob.new, attempts: 3, job_id: "imported-1")

    assert_equal "imported-1", job.job_id
    assert_equal 3, job.attempts
    assert_equal 3, serialized_job("imported-1")["executions"]
  end

  test "enqueue_payload uses the Active Job default queue when there is no queue" do
    job = Delayed::JobWrapper.enqueue_payload(SimpleJob.new, priority: 0)

    assert_equal "default", job.queue
  end

  test "enqueue with a hash raises ArgumentError when the payload does not respond to perform" do
    assert_raises(ArgumentError) { Delayed::Job.enqueue(payload_object: Object.new) }
    assert_raises(ArgumentError) { Delayed::Job.enqueue(Object.new) }
  end

  test "enqueue sets priority, run_at and queue" do
    later = 5.minutes.from_now

    assert_equal 5, Delayed::Job.enqueue(payload_object: SimpleJob.new, priority: 5).priority
    assert_equal 99, Delayed::Job.enqueue(payload_object: SimpleJob.new).priority
    assert_in_delta later, Delayed::Job.enqueue(payload_object: SimpleJob.new, run_at: later).run_at, 1
    assert_equal "tracking", Delayed::Job.enqueue(payload_object: NamedQueueJob.new, queue: "tracking").queue
    assert_equal "default_tracking", Delayed::Job.enqueue(payload_object: SimpleJob.new).queue
    assert_equal "job_tracking", Delayed::Job.enqueue(payload_object: NamedQueueJob.new).queue
  end

  test "enqueue increases the number of queued jobs" do
    Delayed::Job.enqueue SimpleJob.new

    assert_equal 1, queued_jobs.size
  end

  test "enqueue with deprecated positional priority and run_at" do
    later = 5.minutes.from_now
    job = nil

    capture_io { job = Delayed::Job.enqueue(SimpleJob.new, 5, later) }

    assert_equal 5, job.priority
    assert_in_delta later, job.run_at, 1
  end

  test "works with jobs in modules" do
    job = Delayed::Job.enqueue M::ModuleJob.new

    assert_difference -> { M::ModuleJob.runs }, 1 do
      job.invoke_job
    end
  end

  test "does not mutate the options hash" do
    options = { priority: 1 }

    Delayed::Job.enqueue SimpleJob.new, options

    assert_equal({ priority: 1 }, options)
  end

  test "with delay_jobs false it runs the job instead of storing it" do
    Delayed::Worker.delay_jobs = false

    job = Delayed::Job.enqueue SimpleJob.new

    assert_empty queued_jobs
    assert_equal 1, SimpleJob.runs
    assert_instance_of Delayed::JobWrapper, job
    assert_nil job.id
  end

  test "with delay_jobs false exceptions from the job propagate" do
    Delayed::Worker.delay_jobs = false

    assert_raises(RuntimeError) { Delayed::Job.enqueue ErrorJob.new }
  end

  test "delay_jobs proc receives the job" do
    seen = nil
    Delayed::Worker.delay_jobs = ->(job) do
      seen = job
      job.priority > 10
    end

    Delayed::Job.enqueue SimpleJob.new, priority: 5
    assert_equal 1, SimpleJob.runs
    assert_instance_of Delayed::JobWrapper, seen

    Delayed::Job.enqueue SimpleJob.new, priority: 20
    assert_equal 1, SimpleJob.runs
    assert_equal 1, queued_jobs.size
  end

  %w[ before success after ].each do |callback|
    test "calls #{callback} with job" do
      job = Delayed::Job.enqueue(CallbackJob.new)

      job.payload_object.expects(callback).with(job)
      job.invoke_job
    end
  end

  test "calls enqueue, before, success and after callbacks in order" do
    job = Delayed::Job.enqueue(CallbackJob.new)
    assert_equal [ "enqueue" ], CallbackJob.messages

    job.invoke_job
    assert_equal %w[ enqueue before perform success after ], CallbackJob.messages
  end

  test "calls the after callback with an error" do
    job = Delayed::Job.enqueue(CallbackJob.new)
    job.payload_object.expects(:perform).raises(RuntimeError.new("fail"))

    assert_raises(RuntimeError) { job.invoke_job }
    assert_equal [ "enqueue", "before", "error: RuntimeError", "after" ], CallbackJob.messages
  end

  test "calls error when before raises an error" do
    job = Delayed::Job.enqueue(CallbackJob.new)
    job.payload_object.expects(:before).raises(RuntimeError.new("fail"))

    assert_raises(RuntimeError) { job.invoke_job }
    assert_equal [ "enqueue", "error: RuntimeError", "after" ], CallbackJob.messages
  end

  test "hooks without arguments are called without the job" do
    job = Delayed::Job.enqueue(ZeroArityHookJob.new)
    job.invoke_job

    assert_equal %w[ enqueue before perform success after ], ZeroArityHookJob.messages
  end

  test "hook passes extra arguments after the job" do
    job = Delayed::Job.enqueue(CallbackJob.new)
    error = RuntimeError.new("boom")

    job.hook(:error, error)

    assert_equal [ "enqueue", "error: RuntimeError" ], CallbackJob.messages
  end

  test "hook ignores payloads without the hook" do
    job = Delayed::Job.enqueue(SimpleJob.new)

    assert_nil job.hook(:before)
  end

  test "the enqueue hook can change the job before it is stored" do
    freeze_time do
      job = Delayed::Job.enqueue(EnqueueJobMod.new)

      assert_equal 20.minutes.from_now, job.run_at
      assert_in_delta 20.minutes.from_now, solid_queue_jobs(:scheduled).first.scheduled_at, 1
    end
  end

  test "runs the enqueue and invoke_job lifecycle events with the job" do
    events = []
    Delayed::Worker.lifecycle.before(:enqueue) { |job| events << [ :enqueue, job.class ] }
    Delayed::Worker.lifecycle.around(:invoke_job) do |job, &block|
      events << [ :invoke_job, job.class ]
      block.call(job)
    end

    Delayed::Job.enqueue(SimpleJob.new).invoke_job

    assert_equal [ [ :enqueue, Delayed::JobWrapper ], [ :invoke_job, Delayed::JobWrapper ] ], events
  end

  test "custom job objects round-trip through Solid Queue with their state" do
    StatefulJob.performed = []
    Delayed::Job.enqueue StatefulJob.new("counter", 3, { "nested" => [ 1, :two ] })

    perform_ready_jobs

    assert_equal [ [ "counter", 3, { "nested" => [ 1, :two ] } ] ], StatefulJob.performed
  end

  test "struct jobs round-trip through Solid Queue" do
    job = Delayed::Job.enqueue NamedJob.new(:done)

    loaded = ActiveJob::Base.deserialize(serialized_job(job.job_id)).payload_object
    assert_equal NamedJob.new(:done), loaded
  end

  test "jobs performed by Solid Queue run their hooks and finish" do
    Delayed::Job.enqueue(CallbackJob.new)

    perform_ready_jobs

    assert_equal %w[ enqueue before perform success after ], CallbackJob.messages
    assert_empty queued_jobs
    assert_empty solid_queue_jobs(:failed)
  end

  test "display_name and name come from the payload" do
    assert_equal "named_job", Delayed::Job.enqueue(NamedJob.new).name
    assert_equal "ErrorJob", Delayed::Job.enqueue(ErrorJob.new).name
    assert_equal "Story#save", Story.create(text: "...").delay.save.name
    assert_equal "named_job", Delayed::Job.enqueue(NamedJob.new).display_name
  end

  test "name falls back to the payload class when the payload cannot be loaded" do
    story = Story.create(text: "...")
    job = story.delay.text
    story.destroy

    loaded = ActiveJob::Base.deserialize(serialized_job(job.job_id))
    assert_equal "Delayed::PerformableMethod", loaded.name
    assert_raises(Delayed::DeserializationError) { loaded.payload_object }
  end

  test "reloading a job reloads changed record attributes" do
    story = Story.create(text: "hello")
    job = story.delay.tell
    story.text = "goodbye"
    story.save!

    assert_equal "goodbye", ActiveJob::Base.deserialize(serialized_job(job.job_id)).payload_object.object.text
  end

  test "reloading a job with a destroyed record raises DeserializationError" do
    story = Story.create(text: "hello")
    job = story.delay.tell
    story.destroy

    error = assert_raises(Delayed::DeserializationError) { ActiveJob::Base.deserialize(serialized_job(job.job_id)).payload_object }
    assert_match(/\AJob failed to load: /, error.message)
  end

  test "payload_object can be replaced" do
    job = Delayed::JobWrapper.new(SimpleJob.new)
    replacement = NamedJob.new

    job.payload_object = replacement

    assert_same replacement, job.payload_object
    assert_equal [ replacement ], job.arguments
  end

  test "error= records the message and backtrace in last_error" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    error = RuntimeError.new("went wrong").tap { |e| e.set_backtrace([ "a.rb:1", "b.rb:2" ]) }

    job.error = error

    assert_same error, job.error
    assert_equal "went wrong\na.rb:1\nb.rb:2", job.last_error
  end

  test "failed? reflects failed_at" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    assert_not job.failed?
    assert_not job.failed

    job.failed_at = Time.current
    assert job.failed?
  end

  test "unlock clears locks" do
    job = Delayed::Job.enqueue(SimpleJob.new)
    job.locked_by = "worker"
    job.locked_at = Time.current

    job.unlock

    assert_nil job.locked_by
    assert_nil job.locked_at
  end

  test "a large payload gets an id" do
    job = Delayed::Job.enqueue Delayed::PerformableMethod.new("Lorem ipsum dolor sit amet. " * 1000, :length, {})

    assert_not_nil job.id
  end

  test "publishes enqueue.delayed_job with the job details" do
    events = capture_delayed_job_events { @job = Delayed::Job.enqueue(NamedJob.new, queue: "events", priority: 4) }

    enqueue = events.find { |event| event.name == "enqueue.delayed_job" }
    assert_equal({ display_name: "named_job", job_id: @job.job_id, queue: "events", priority: 4, attempts: 0 }, enqueue.payload.slice(:display_name, :job_id, :queue, :priority, :attempts))
  end

  test "publishes perform.delayed_job when Solid Queue runs the job" do
    job = Delayed::Job.enqueue(SimpleJob.new)

    events = capture_delayed_job_events { perform_ready_jobs }

    perform = events.find { |event| event.name == "perform.delayed_job" }
    assert_equal job.job_id, perform.payload[:job_id]
    assert_equal "SimpleJob", perform.payload[:display_name]
    assert_equal 0, perform.payload[:attempts]
    assert perform.payload[:success]
  end

  test "delivery_mode defaults to Delayed::Worker.delivery_mode" do
    assert_equal :exactly_once, Delayed::Job.enqueue(SimpleJob.new).delivery_mode

    Delayed::Worker.delivery_mode = :at_least_once
    assert_equal :at_least_once, Delayed::Job.enqueue(SimpleJob.new).delivery_mode
  end

  test "delivery_mode uses the payload's delivery_mode over the worker default" do
    assert_equal :at_most_once, Delayed::Job.enqueue(AtMostOnceJob.new).delivery_mode
  end

  test "the delivery_mode option wins over the payload and the worker default" do
    Delayed::Worker.delivery_mode = :at_most_once

    assert_equal :at_least_once, Delayed::Job.enqueue(AtMostOnceJob.new, delivery_mode: :at_least_once).delivery_mode
    assert_equal :exactly_once, Delayed::Job.enqueue(payload_object: SimpleJob.new, delivery_mode: "exactly_once").delivery_mode
  end

  test "enqueue_payload takes the delivery_mode option" do
    assert_equal :at_most_once, Delayed::JobWrapper.enqueue_payload(SimpleJob.new, delivery_mode: :at_most_once).delivery_mode
    assert_equal :exactly_once, Delayed::JobWrapper.enqueue_payload(SimpleJob.new, delivery_mode: nil).delivery_mode
  end

  test "an unknown delivery_mode option raises before anything is stored" do
    error = assert_raises(ArgumentError) { Delayed::Job.enqueue(SimpleJob.new, delivery_mode: :twice) }

    assert_equal "Unknown delivery mode :twice. Use :at_least_once, :at_most_once or :exactly_once.", error.message
    assert_empty queued_jobs
  end

  test "an unknown payload delivery_mode raises before anything is stored" do
    payload = SimpleJob.new
    payload.define_singleton_method(:delivery_mode) { :sometimes }

    assert_raises(ArgumentError) { Delayed::Job.enqueue(payload) }
    assert_empty queued_jobs
  end

  test "delayed methods ignore a delivery_mode on the target object" do
    job = Notifier.new("sms").delay.notify

    assert_equal :exactly_once, job.delivery_mode
    perform_ready_jobs
    assert_equal [ "sms" ], Notifier.sent
  end

  test "delivery_mode falls back to the worker default when the payload cannot be loaded" do
    story = Story.create(text: "hello")
    job = story.delay.tell
    story.destroy

    assert_equal :exactly_once, ActiveJob::Base.deserialize(serialized_job(job.job_id)).delivery_mode
  end

  test "the delivery_mode option round-trips through the stored job" do
    job = Delayed::Job.enqueue(AtMostOnceJob.new, delivery_mode: :at_least_once)

    assert_equal "at_least_once", serialized_job(job.job_id)["delivery_mode"]
    assert_equal :at_least_once, ActiveJob::Base.deserialize(serialized_job(job.job_id)).delivery_mode
  end

  test "jobs without a delivery_mode option store none and resolve it when loaded" do
    job = Delayed::Job.enqueue(AtMostOnceJob.new)

    assert_not serialized_job(job.job_id).key?("delivery_mode")
    assert_equal :at_most_once, ActiveJob::Base.deserialize(serialized_job(job.job_id)).delivery_mode
  end

  test "retries keep the delivery_mode option" do
    job = Delayed::Job.enqueue(ErrorJob.new, delivery_mode: :at_most_once)

    perform_ready_jobs

    rescheduled = solid_queue_jobs(:scheduled).sole
    assert_equal job.job_id, rescheduled.active_job_id
    assert_equal "at_most_once", rescheduled.arguments["delivery_mode"]
  end

  test "Delayed::Worker.delivery_mode leaves other Active Job classes alone" do
    plain = Class.new(ActiveJob::Base)
    default = SolidQueue.try(:default_delivery_mode)

    Delayed::Worker.delivery_mode = :at_most_once

    assert_equal default, SolidQueue.try(:default_delivery_mode)
    assert_not_equal :at_most_once, plain.new.try(:delivery_mode)
  end

  test "Solid Queue stores the delivery mode of each job" do
    skip "needs Solid Queue delivery modes" unless SolidQueue.respond_to?(:default_delivery_mode)

    default = Delayed::Job.enqueue(SimpleJob.new)
    opted_out = Delayed::Job.enqueue(SimpleJob.new, delivery_mode: :at_least_once)
    from_payload = Delayed::Job.enqueue(AtMostOnceJob.new)

    assert_equal "exactly_once", solid_queue_job(default.job_id).delivery_mode.to_s
    assert_equal "at_least_once", solid_queue_job(opted_out.job_id).delivery_mode.to_s
    assert_equal "at_most_once", solid_queue_job(from_payload.job_id).delivery_mode.to_s
  end

  test "Solid Queue keeps its own default delivery mode for plain Active Job jobs" do
    skip "needs Solid Queue delivery modes" unless SolidQueue.respond_to?(:default_delivery_mode)

    job = PlainActiveJob.perform_later

    assert_equal SolidQueue.default_delivery_mode.to_s, solid_queue_job(job.job_id).delivery_mode.to_s
  end

  test "Active Job does not log the payload arguments" do
    assert_not Delayed::JobWrapper.log_arguments?
    assert PlainActiveJob.log_arguments?

    output = StringIO.new
    previous = ActiveJob::Base.logger
    ActiveJob::Base.logger = ActiveSupport::Logger.new(output)
    begin
      Delayed::Job.enqueue StatefulJob.new("secret-token", 1)
      perform_ready_jobs
    ensure
      ActiveJob::Base.logger = previous
    end

    assert_includes output.string, "Delayed::JobWrapper"
    assert_not_includes output.string, "secret-token"
  end

  test "Solid Queue job names use the payload display_name" do
    assert Delayed::JobWrapper.method_defined?(:display_name)

    job = ActiveJob::Base.deserialize(serialized_job(Delayed::Job.enqueue(NamedJob.new).job_id))
    assert_equal "named_job", job.display_name
  end
end
