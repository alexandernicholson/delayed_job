# frozen_string_literal: true

require "test_helper"

class BackendBaseTest < ActiveSupport::TestCase
  include OpsTestHelper

  setup do
    OpsMemoryJob.delete_all
    CallbackJob.messages = []
    M::ModuleJob.runs = 0
  end

  teardown do
    Delayed::Backend::Base::HandlerLoader.permitted_classes = []
  end

  test "enqueue with a hash raises ArgumentError when the payload does not respond to perform" do
    assert_raises(ArgumentError) { OpsMemoryJob.enqueue(payload_object: Object.new) }
  end

  test "enqueue with arguments raises ArgumentError when the payload does not respond to perform" do
    assert_raises(ArgumentError) { OpsMemoryJob.enqueue(Object.new) }
  end

  test "enqueue increases count" do
    OpsMemoryJob.enqueue SimpleJob.new
    assert_equal 1, OpsMemoryJob.count
  end

  test "enqueue does not mutate the options hash" do
    options = { priority: 1 }
    OpsMemoryJob.enqueue SimpleJob.new, options
    assert_equal({ priority: 1 }, options)
  end

  test "enqueue sets the payload, priority, queue and run_at from options" do
    later = 5.minutes.from_now
    job = OpsMemoryJob.enqueue(payload_object: SimpleJob.new, priority: 3, queue: "tracking", run_at: later)
    assert_instance_of SimpleJob, job.payload_object
    assert_equal 3, job.priority
    assert_equal "tracking", job.queue
    assert_equal later, job.run_at
  end

  test "enqueue uses Delayed::Backend::JobPreparer when it prepares options" do
    preparer = mock("preparer")
    preparer.expects(:prepare).returns(payload_object: SimpleJob.new, priority: 7)
    Delayed::Backend::JobPreparer.any_instance.stubs(:prepare)
    Delayed::Backend::JobPreparer.expects(:new).with(SimpleJob, { priority: 1 }).returns(preparer)

    job = OpsMemoryJob.enqueue(SimpleJob, priority: 1)

    assert_equal 7, job.priority
  end

  test "enqueue works with jobs in modules" do
    job = OpsMemoryJob.enqueue M::ModuleJob.new
    assert_difference -> { M::ModuleJob.runs }, 1 do
      job.invoke_job
    end
  end

  test "enqueue_job returns an instance of the backend" do
    assert_instance_of OpsMemoryJob, OpsMemoryJob.enqueue_job(payload_object: SimpleJob.new)
  end

  test "enqueue_job calls the payload enqueue hook before saving" do
    job = OpsMemoryJob.enqueue(CallbackJob.new)
    assert_equal [ "enqueue" ], CallbackJob.messages
    assert_includes OpsMemoryJob.all, job
  end

  test "enqueue_job lets the enqueue hook change the job before it is saved" do
    freeze_time
    job = OpsMemoryJob.enqueue(EnqueueJobMod.new)
    assert_equal 20.minutes.from_now, job.run_at
  end

  test "enqueue_job runs the enqueue lifecycle callbacks around saving" do
    events = []
    lifecycle = Object.new
    lifecycle.define_singleton_method(:run_callbacks) do |event, *args, &block|
      events << [ event, args.first.class ]
      block.call(*args)
    end
    Delayed::Worker.stubs(:lifecycle).returns(lifecycle)

    OpsMemoryJob.enqueue(SimpleJob.new)

    assert_equal [ [ :enqueue, OpsMemoryJob ] ], events
    assert_equal 1, OpsMemoryJob.count
  end

  test "with delay_jobs false it does not save the job" do
    Delayed::Worker.delay_jobs = false
    OpsMemoryJob.enqueue SimpleJob.new
    assert_equal 0, OpsMemoryJob.count
  end

  test "with delay_jobs false it invokes the job" do
    Delayed::Worker.delay_jobs = false
    OpsMemoryJob.enqueue SimpleJob.new
    assert_equal 1, SimpleJob.runs
  end

  test "with delay_jobs false it returns a job, not the result of invocation" do
    Delayed::Worker.delay_jobs = false
    assert_instance_of OpsMemoryJob, OpsMemoryJob.enqueue(SimpleJob.new)
  end

  test "delay_jobs accepts a proc that receives the job" do
    seen = nil
    Delayed::Worker.delay_jobs = lambda do |job|
      seen = job
      false
    end
    job = OpsMemoryJob.enqueue(SimpleJob.new)
    assert_same job, seen
    assert_equal 0, OpsMemoryJob.count
  end

  test "delay_jobs accepts a proc without arguments" do
    Delayed::Worker.delay_jobs = -> { true }
    OpsMemoryJob.enqueue(SimpleJob.new)
    assert_equal 1, OpsMemoryJob.count
  end

  test "enqueue_job uses Delayed::Worker.delay_job? when it is defined" do
    Delayed::Worker.stubs(:delay_job?).returns(false)
    OpsMemoryJob.enqueue(SimpleJob.new)
    assert_equal 0, OpsMemoryJob.count
    assert_equal 1, SimpleJob.runs
  end

  test "reserve returns the first available job it can lock for the worker" do
    job = OpsMemoryJob.create(payload_object: SimpleJob.new)
    worker = OpsWorker.new("worker-a")

    assert_equal job, OpsMemoryJob.reserve(worker)
    assert_equal "worker-a", job.locked_by
  end

  test "reserve asks for read_ahead candidates with the given max_run_time" do
    worker = OpsWorker.new("worker-a", 3)
    OpsMemoryJob.expects(:find_available).with("worker-a", 3, 10.minutes).returns([])
    assert_nil OpsMemoryJob.reserve(worker, 10.minutes)
  end

  test "reserve defaults max_run_time to Delayed::Worker.max_run_time" do
    ops_worker_setting(:max_run_time, 7.minutes)
    OpsMemoryJob.expects(:find_available).with("worker-a", 5, 7.minutes).returns([])
    OpsMemoryJob.reserve(OpsWorker.new("worker-a"))
  end

  test "reserve skips candidates that cannot be locked" do
    locked, open = 2.times.map { OpsMemoryJob.create(payload_object: SimpleJob.new) }
    locked.stubs(:lock_exclusively!).returns(false)
    OpsMemoryJob.stubs(:find_available).returns([ locked, open ])

    assert_equal open, OpsMemoryJob.reserve(OpsWorker.new)
  end

  test "recover_from, before_fork and after_fork are no-op hooks" do
    assert_nil OpsMemoryJob.recover_from(StandardError.new)
    assert_nil OpsMemoryJob.before_fork
    assert_nil OpsMemoryJob.after_fork
  end

  test "work_off is deprecated and delegates to a new worker" do
    worker = mock("worker")
    worker.expects(:work_off).with(7).returns([ 7, 0 ])
    Delayed::Worker.expects(:new).returns(worker)

    _, err = capture_io { assert_equal [ 7, 0 ], OpsMemoryJob.work_off(7) }

    assert_match(/\[DEPRECATION\] `Delayed::Job.work_off` is deprecated/, err)
  end

  test "error= records the error and last_error" do
    job = OpsMemoryJob.new
    error = RuntimeError.new("boom").tap { |e| e.set_backtrace([ "a.rb:1", "b.rb:2" ]) }

    job.error = error

    assert_same error, job.error
    assert_equal "boom\na.rb:1\nb.rb:2", job.last_error
  end

  test "error= accepts an error without backtrace" do
    job = OpsMemoryJob.new
    job.error = RuntimeError.new("boom")
    assert_equal "boom\n", job.last_error
  end

  test "failed? reflects failed_at" do
    job = OpsMemoryJob.new
    assert_not job.failed?
    job.failed_at = Time.current
    assert job.failed?
    assert job.failed
  end

  test "name is the class name of the payload" do
    assert_equal "ErrorJob", OpsMemoryJob.create(payload_object: ErrorJob.new).name
  end

  test "name is the payload display_name when it defines one" do
    assert_equal "named_job", OpsMemoryJob.new(payload_object: NamedJob.new).name
  end

  test "name is parsed from the handler when the payload cannot be deserialized" do
    job = OpsMemoryJob.new(handler: "--- !ruby/object:JobThatDoesNotExist {}\n")
    assert_equal "JobThatDoesNotExist", job.name
  end

  test "payload_object= stores the payload and its YAML handler" do
    job = OpsMemoryJob.new
    payload = SimpleJob.new
    job.payload_object = payload
    assert_same payload, job.payload_object
    assert_equal payload.to_yaml, job.handler
  end

  test "payload_object raises DeserializationError when the job class is unknown" do
    job = OpsMemoryJob.new(handler: "--- !ruby/object:JobThatDoesNotExist {}")
    assert_raises(Delayed::DeserializationError) { job.payload_object }
  end

  test "payload_object raises DeserializationError when the job struct is unknown" do
    job = OpsMemoryJob.new(handler: "--- !ruby/struct:StructThatDoesNotExist {}")
    assert_raises(Delayed::DeserializationError) { job.payload_object }
  end

  test "payload_object raises DeserializationError when loading raises ArgumentError" do
    job = OpsMemoryJob.new(handler: "--- !ruby/struct:GoingToRaiseArgError {}")
    Delayed::Backend::Base::HandlerLoader.expects(:load).raises(ArgumentError)
    assert_raises(Delayed::DeserializationError) { job.payload_object }
  end

  test "payload_object raises DeserializationError on YAML syntax errors" do
    job = OpsMemoryJob.new(handler: 'message: "no ending quote')
    assert_raises(Delayed::DeserializationError) { job.payload_object }
  end

  test "payload_object raises DeserializationError for classes that are not permitted" do
    job = OpsMemoryJob.new(handler: SimpleJob.new.to_yaml)
    error = assert_raises(Delayed::DeserializationError) { job.payload_object }
    assert_match "SimpleJob", error.message
  end

  test "payload_object loads classes added to the permitted list" do
    Delayed::Backend::Base::HandlerLoader.permitted_classes = [ SimpleJob ]
    job = OpsMemoryJob.new(handler: SimpleJob.new.to_yaml)
    assert_instance_of SimpleJob, job.payload_object
  end

  %i[ before success after ].each do |callback|
    test "invoke_job calls #{callback} with the job" do
      job = OpsMemoryJob.enqueue(CallbackJob.new)
      job.payload_object.expects(callback).with(job)
      job.invoke_job
    end
  end

  test "invoke_job calls before and after callbacks" do
    job = OpsMemoryJob.enqueue(CallbackJob.new)
    assert_equal [ "enqueue" ], CallbackJob.messages
    job.invoke_job
    assert_equal %w[ enqueue before perform success after ], CallbackJob.messages
  end

  test "invoke_job calls the after callback with an error" do
    job = OpsMemoryJob.enqueue(CallbackJob.new)
    job.payload_object.expects(:perform).raises(RuntimeError.new("fail"))

    assert_raises(RuntimeError) { job.invoke_job }
    assert_equal [ "enqueue", "before", "error: RuntimeError", "after" ], CallbackJob.messages
  end

  test "invoke_job calls error when before raises an error" do
    job = OpsMemoryJob.enqueue(CallbackJob.new)
    job.payload_object.expects(:before).raises(RuntimeError.new("fail"))

    assert_raises(RuntimeError) { job.invoke_job }
    assert_equal [ "enqueue", "error: RuntimeError", "after" ], CallbackJob.messages
  end

  test "invoke_job runs the invoke_job lifecycle callbacks" do
    events = []
    lifecycle = Object.new
    lifecycle.define_singleton_method(:run_callbacks) do |event, *args, &block|
      events << event
      block.call(*args)
    end
    job = OpsMemoryJob.new(payload_object: SimpleJob.new)
    Delayed::Worker.stubs(:lifecycle).returns(lifecycle)

    job.invoke_job

    assert_equal [ :invoke_job ], events
    assert_equal 1, SimpleJob.runs
  end

  test "unlock clears the lock" do
    job = OpsMemoryJob.create(payload_object: SimpleJob.new, locked_by: "worker", locked_at: Time.current)
    job.unlock
    assert_nil job.locked_by
    assert_nil job.locked_at
  end

  test "hook calls zero arity hooks without arguments" do
    payload = Class.new(SimpleJob) { def before = self.class.runs += 10 }.new
    OpsMemoryJob.new(payload_object: payload).hook(:before)
    assert_equal 10, SimpleJob.runs
  end

  test "hook ignores hooks the payload does not define" do
    assert_nil OpsMemoryJob.new(payload_object: SimpleJob.new).hook(:before)
  end

  test "hook swallows deserialization errors" do
    assert_nil OpsMemoryJob.new(handler: "--- !ruby/object:JobThatDoesNotExist {}").hook(:enqueue)
  end

  test "reschedule_at uses attempts**4 + 5 seconds" do
    freeze_time
    job = OpsMemoryJob.new(payload_object: SimpleJob.new, attempts: 2)
    assert_equal Time.current + 21, job.reschedule_at
  end

  test "reschedule_at uses the payload reschedule_at when defined" do
    freeze_time
    job = OpsMemoryJob.new(payload_object: CustomRescheduleJob.new(99.minutes), attempts: 3)
    assert_equal 99.minutes.from_now, job.reschedule_at
  end

  test "max_attempts is not defined by default" do
    assert_nil OpsMemoryJob.enqueue(SimpleJob.new).max_attempts
  end

  test "max_attempts uses the payload value when defined" do
    job = OpsMemoryJob.enqueue(SimpleJob.new)
    job.payload_object.expects(:max_attempts).returns(99)
    assert_equal 99, job.max_attempts
  end

  test "max_run_time is not defined by default" do
    assert_nil OpsMemoryJob.enqueue(SimpleJob.new).max_run_time
  end

  test "max_run_time uses the payload value when defined" do
    job = OpsMemoryJob.enqueue(SimpleJob.new)
    job.payload_object.expects(:max_run_time).returns(30.minutes)
    assert_equal 30.minutes, job.max_run_time
  end

  test "max_run_time can not exceed Delayed::Worker.max_run_time" do
    ops_worker_setting(:max_run_time, 4.hours)
    job = OpsMemoryJob.enqueue(SimpleJob.new)
    job.payload_object.expects(:max_run_time).returns(4.hours + 60)
    assert_equal 4.hours, job.max_run_time
  end

  test "max_run_time is nil when the payload returns nil" do
    job = OpsMemoryJob.enqueue(SimpleJob.new)
    job.payload_object.expects(:max_run_time).returns(nil)
    assert_nil job.max_run_time
  end

  test "destroy_failed_jobs? defaults to Delayed::Worker.destroy_failed_jobs" do
    ops_worker_setting(:destroy_failed_jobs, true)
    assert OpsMemoryJob.enqueue(SimpleJob.new).destroy_failed_jobs?
  end

  test "destroy_failed_jobs? uses the payload value when defined" do
    ops_worker_setting(:destroy_failed_jobs, true)
    job = OpsMemoryJob.enqueue(SimpleJob.new)
    job.payload_object.expects(:destroy_failed_jobs?).returns(false)
    assert_equal false, job.destroy_failed_jobs?
  end

  test "destroy_failed_jobs? falls back to the worker setting on deserialization errors" do
    ops_worker_setting(:destroy_failed_jobs, true)
    job = OpsMemoryJob.new(handler: "--- !ruby/struct:GoingToRaiseArgError {}")
    Delayed::Backend::Base::HandlerLoader.expects(:load).raises(ArgumentError)
    assert_equal true, job.destroy_failed_jobs?
  end

  test "fail! sets failed_at and saves" do
    freeze_time
    job = OpsMemoryJob.new(payload_object: SimpleJob.new)
    job.expects(:save!)
    job.fail!
    assert_equal Time.current, job.failed_at
  end

  test "saving sets run_at when it is not set" do
    assert_not_nil OpsMemoryJob.create(payload_object: ErrorJob.new).run_at
  end

  test "saving keeps run_at when it is set" do
    later = 5.minutes.from_now
    assert_equal later, OpsMemoryJob.create(payload_object: ErrorJob.new, run_at: later).run_at
  end

  test "reload resets the payload" do
    Delayed::Backend::Base::HandlerLoader.permitted_classes = [ SimpleJob ]
    job = OpsMemoryJob.enqueue(payload_object: SimpleJob.new)
    assert_not_equal job.payload_object.object_id, job.reload.payload_object.object_id
  end

  test "HandlerLoader loads plain YAML values" do
    loaded = Delayed::Backend::Base::HandlerLoader.load({ "a" => :b, "t" => Time.utc(2026, 1, 1) }.to_yaml)
    assert_equal({ "a" => :b, "t" => Time.utc(2026, 1, 1) }, loaded)
  end

  test "HandlerLoader resolves class and module references" do
    assert_equal SimpleJob, Delayed::Backend::Base::HandlerLoader.load("--- !ruby/class 'SimpleJob'\n")
    assert_equal M, Delayed::Backend::Base::HandlerLoader.load("--- !ruby/module 'M'\n")
  end

  test "HandlerLoader rejects unknown class references" do
    assert_raises(NameError) { Delayed::Backend::Base::HandlerLoader.load("--- !ruby/class 'NoSuchClass'\n") }
  end

  test "HandlerLoader accepts extra permitted classes per call" do
    assert_instance_of SimpleJob, Delayed::Backend::Base::HandlerLoader.load(SimpleJob.new.to_yaml, permitted_classes: [ SimpleJob ])
  end

  test "HandlerLoader loads Active Record objects by primary key" do
    skip_unless_story!
    story = OpsStory.create!(text: "hello")
    yaml = "--- !ruby/ActiveRecord:OpsStory\nattributes:\n  id: #{story.id}\n  text: stale\n"
    assert_equal story, Delayed::Backend::Base::HandlerLoader.load(yaml)
  end

  test "HandlerLoader loads Active Record objects serialized by Psych" do
    skip_unless_story!
    story = OpsStory.create!(text: "hello")
    loaded = Delayed::Backend::Base::HandlerLoader.load(story.to_yaml)
    assert_equal story, loaded
    assert_equal "hello", loaded.text
  end

  test "HandlerLoader raises DeserializationError for missing records" do
    skip_unless_story!
    yaml = "--- !ruby/ActiveRecord:OpsStory\nattributes:\n  id: 0\n"
    assert_raises(Delayed::DeserializationError) { Delayed::Backend::Base::HandlerLoader.load(yaml) }
  end

  test "HandlerLoader refuses record tags naming classes that are not records" do
    File.expects(:find).never
    assert_raises(ArgumentError) { Delayed::Backend::Base::HandlerLoader.load("--- !ruby/ActiveRecord:File\nattributes:\n  id: 1\n") }
  end

  test "HandlerLoader builds performable methods for class receivers through their constructor" do
    Delayed::PerformableMethod.expects(:new).with(SimpleJob, :new, [ 1 ]).returns(:built)
    yaml = "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/class 'SimpleJob'\nmethod_name: :new\nargs: [1]\n"
    assert_equal :built, Delayed::Backend::Base::HandlerLoader.load(yaml)
  end

  {
    "Kernel.system" => "object: !ruby/module 'Kernel'\nmethod_name: :system\nargs: [\"true\"]",
    "Object.eval" => "object: !ruby/class 'Object'\nmethod_name: :eval\nargs: [\"1\"]",
    "a private method" => "object: !ruby/class 'SimpleJob'\nmethod_name: :puts\nargs: []",
    "send" => "object: !ruby/class 'SimpleJob'\nmethod_name: :send\nargs: [exit]",
    "instance_eval" => "object: a string\nmethod_name: :instance_eval\nargs: [\"1\"]",
    "File.write" => "object: !ruby/class 'File'\nmethod_name: :write\nargs: [\"/tmp/x\", \"y\"]"
  }.each do |description, body|
    test "HandlerLoader refuses performable methods calling #{description}" do
      Delayed::PerformableMethod.expects(:new).never
      yaml = "--- !ruby/object:Delayed::PerformableMethod\n#{body}\n"
      assert_raises(ArgumentError) { Delayed::Backend::Base::HandlerLoader.load(yaml) }
    end
  end

  [ "!ruby/hash-with-ivars:Delayed::PerformableMethod\nivars:\n  :@object: 1\n", "!ruby/struct:Delayed::PerformableMethod\nobject: 1\n",
    "!ruby/array:Delayed::PerformableMailer\n- 1\n", "!ruby/object:Delayed::PerformableMethod ''\n" ].each do |document|
    test "HandlerLoader refuses #{document.split("\n").first} documents" do
      Delayed::PerformableMethod.expects(:allocate).never
      Delayed::PerformableMailer.expects(:allocate).never
      assert_raises(ArgumentError) { Delayed::Backend::Base::HandlerLoader.load("--- #{document}") }
    end
  end

  test "payload_object wraps refused handlers in DeserializationError" do
    job = OpsMemoryJob.new(handler: "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/module 'Kernel'\nmethod_name: :system\nargs: []\n")
    assert_raises(Delayed::DeserializationError) { job.payload_object }
  end

  test "HandlerLoader builds performable methods through their constructor" do
    yaml = "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/class 'SimpleJob'\nmethod_name: :new\nargs: []\n"
    loaded = Delayed::Backend::Base::HandlerLoader.load(yaml)
    assert_instance_of Delayed::PerformableMethod, loaded
    assert_equal SimpleJob, loaded.object
    assert_equal :new, loaded.method_name
  end
end
