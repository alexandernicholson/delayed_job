# frozen_string_literal: true

require "test_helper"

class JobPreparerTest < ActiveSupport::TestCase
  setup do
    Delayed::Worker.default_priority = 99
    Delayed::Worker.default_queue_name = "default_tracking"
  end

  test "prepare returns the options with the payload, queue and priority" do
    job = SimpleJob.new

    options = prepare(payload_object: job)

    assert_equal({ payload_object: job, queue: "default_tracking", priority: 99 }, options)
  end

  test "exposes the options and args" do
    job = SimpleJob.new
    preparer = Delayed::Backend::JobPreparer.new(job, 5, priority: 1)

    assert_equal({ priority: 1 }, preparer.options)
    assert_equal [ job, 5 ], preparer.args
  end

  test "takes the payload from the first positional argument" do
    job = SimpleJob.new

    assert_same job, prepare(job)[:payload_object]
  end

  test "raises ArgumentError when the payload does not respond to perform" do
    error = assert_raises(ArgumentError) { prepare(payload_object: Object.new) }
    assert_equal "Cannot enqueue items which do not respond to perform", error.message

    assert_raises(ArgumentError) { prepare(Object.new) }
  end

  test "keeps the given priority" do
    assert_equal 5, prepare(payload_object: SimpleJob.new, priority: 5)[:priority]
  end

  test "uses the default priority" do
    assert_equal 99, prepare(payload_object: SimpleJob.new)[:priority]
  end

  test "keeps the given queue even when the payload has a queue_name" do
    assert_equal "tracking", prepare(payload_object: NamedQueueJob.new, queue: "tracking")[:queue]
  end

  test "uses the default queue name" do
    assert_equal "default_tracking", prepare(payload_object: SimpleJob.new)[:queue]
  end

  test "uses a nil queue when there is no default queue name" do
    Delayed::Worker.default_queue_name = nil

    assert_nil prepare(payload_object: SimpleJob.new)[:queue]
  end

  test "uses the payload object's queue_name" do
    assert_equal "job_tracking", prepare(payload_object: NamedQueueJob.new)[:queue]
  end

  test "sets priority from queue_attributes" do
    Delayed::Worker.queue_attributes = { "job_tracking" => { priority: 4 } }

    assert_equal 4, prepare(payload_object: NamedQueueJob.new)[:priority]
    assert_equal 4, prepare(payload_object: SimpleJob.new, queue: :job_tracking)[:priority]
  end

  test "passed priority overrides queue_attributes" do
    Delayed::Worker.queue_attributes = { "job_tracking" => { priority: 4 } }

    assert_equal 10, prepare(payload_object: NamedQueueJob.new, priority: 10)[:priority]
  end

  test "queue_attributes without a priority fall back to the default priority" do
    Delayed::Worker.queue_attributes = { "job_tracking" => { other: 1 } }

    assert_equal 99, prepare(payload_object: NamedQueueJob.new)[:priority]
  end

  test "positional priority is deprecated" do
    options = nil

    assert_output(nil, "[DEPRECATION] Passing multiple arguments to `#enqueue` is deprecated. Pass a hash with :priority and :run_at.\n") do
      options = prepare(SimpleJob.new, 5)
    end
    assert_equal 5, options[:priority]
    assert_nil options[:run_at]
  end

  test "positional run_at is deprecated" do
    later = 5.minutes.from_now

    options = nil
    capture_io { options = prepare(SimpleJob.new, 5, later) }

    assert_equal 5, options[:priority]
    assert_equal later, options[:run_at]
  end

  test "a nil positional priority keeps the resolved priority" do
    options = nil
    capture_io { options = prepare(SimpleJob.new, nil, 1.minute.from_now) }

    assert_equal 99, options[:priority]
  end

  test "keeps the delivery_mode option" do
    assert_equal :at_most_once, prepare(payload_object: SimpleJob.new, delivery_mode: :at_most_once)[:delivery_mode]
    assert_equal :at_least_once, prepare(SimpleJob.new, delivery_mode: :at_least_once)[:delivery_mode]
  end

  test "does not mutate the options hash" do
    options = { priority: 1 }

    prepare(SimpleJob.new, options)

    assert_equal({ priority: 1 }, options)
  end

  private
    def prepare(*args)
      Delayed::Backend::JobPreparer.new(*args).prepare
    end
end
