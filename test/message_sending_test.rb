# frozen_string_literal: true

require "test_helper"

class MessageSendingTest < ActiveSupport::TestCase
  class FairyTail
    attr_accessor :happy_ending

    def self.princesses; end

    def tell
      @happy_ending = true
    end
  end

  class Fable
    cattr_accessor :importance

    def tell; end
    handle_asynchronously :tell, priority: proc { importance }
  end

  class Yarn
    attr_accessor :importance

    def spin; end
    handle_asynchronously :spin, priority: proc { |yarn| yarn.importance }
  end

  class Chapter
    cattr_accessor :calls, default: []
    attr_accessor :queue_for, :deadline

    def read!(page)
      self.class.calls << [ :read!, page ]
    end
    handle_asynchronously :read!

    def finished?
      self.class.calls << :finished?
    end
    handle_asynchronously :finished?

    def title=(title)
      self.class.calls << [ :title=, title ]
    end
    handle_asynchronously :title=

    def publish; end
    handle_asynchronously :publish, queue: proc { |chapter| chapter.queue_for }, run_at: proc { |chapter| chapter.deadline }

    def archive; end
    handle_asynchronously :archive, queue: "archive", priority: 7, run_at: -> { 1.hour.from_now }

    def index; end
    handle_asynchronously :index, delivery_mode: :at_least_once

    def reindex; end
    handle_asynchronously :reindex, delivery_mode: proc { |chapter| chapter.queue_for == "bulk" ? :at_most_once : :exactly_once }

    protected
      def reviewed; end
      handle_asynchronously :reviewed

    private
      def drafted; end
      handle_asynchronously :drafted
  end

  teardown do
    Delayed::Worker.default_queue_name = nil
    Chapter.calls = []
  end

  test "does not include ClassMethods along with MessageSending" do
    assert_raises(NameError) { Object.const_get(:ClassMethods) }
    assert_not Delayed::MessageSending.const_defined?(:ClassMethods)
    assert_empty String.ancestors.select { |mod| mod.const_defined?(:ClassMethods, false) && mod.name.to_s.start_with?("Delayed") }
  end

  test "Object includes MessageSending and Module includes MessageSendingClassMethods" do
    assert_includes Object.ancestors, Delayed::MessageSending
    assert_includes Module.ancestors, Delayed::MessageSendingClassMethods
  end

  test "handle_asynchronously aliases the original method" do
    assert_respond_to Story.new, :whatever_without_delay
    assert_respond_to Story.new, :whatever_with_delay
  end

  test "handle_asynchronously creates a PerformableMethod job" do
    story = Story.create(text: "once")

    assert_difference -> { queued_jobs.size }, 1 do
      job = story.whatever(1, 5)

      assert_equal Delayed::PerformableMethod, job.payload_object.class
      assert_equal :whatever_without_delay, job.payload_object.method_name
      assert_equal [ 1, 5 ], job.payload_object.args
    end
  end

  test "handle_asynchronously keeps punctuation at the end of the aliases" do
    chapter = Chapter.new

    %w[ read_with_delay! read_without_delay! finished_with_delay? finished_without_delay? title_with_delay= title_without_delay= ].each do |name|
      assert_respond_to chapter, name
    end

    assert_equal :read_without_delay!, chapter.read!(3).payload_object.method_name
    assert_equal :finished_without_delay?, chapter.finished?.payload_object.method_name
    assert_equal :title_without_delay=, chapter.public_send(:title=, "One").payload_object.method_name
    assert_empty Chapter.calls
  end

  test "handle_asynchronously jobs call the original method when they run" do
    chapter = Chapter.new
    chapter.read!(3)
    chapter.public_send(:title=, "One")

    perform_ready_jobs

    assert_equal [ [ :read!, 3 ], [ :title=, "One" ] ], Chapter.calls
  end

  test "handle_asynchronously keeps the method visibility" do
    assert Chapter.public_method_defined?(:read!)
    assert Chapter.protected_method_defined?(:reviewed)
    assert Chapter.private_method_defined?(:drafted)
  end

  test "handle_asynchronously sets the priority from a zero-arity proc" do
    Fable.importance = 10
    assert_equal 10, Fable.new.tell.priority

    Fable.importance = 20
    assert_equal 20, Fable.new.tell.priority
  end

  test "handle_asynchronously sets the priority from a proc taking the instance" do
    assert_equal 10, Yarn.new.tap { |yarn| yarn.importance = 10 }.spin.priority
    assert_equal 20, Yarn.new.tap { |yarn| yarn.importance = 20 }.spin.priority
  end

  test "handle_asynchronously sets queue and run_at from procs" do
    deadline = 2.hours.from_now.change(usec: 0)
    chapter = Chapter.new
    chapter.queue_for = "editors"
    chapter.deadline = deadline

    job = chapter.publish

    assert_equal "editors", job.queue
    assert_equal deadline, job.run_at
  end

  test "handle_asynchronously accepts plain values and lambdas" do
    freeze_time do
      job = Chapter.new.archive

      assert_equal "archive", job.queue
      assert_equal 7, job.priority
      assert_equal 1.hour.from_now, job.run_at
    end
  end

  test "handle_asynchronously passes delivery_mode as a value or a proc" do
    chapter = Chapter.new
    assert_equal :at_least_once, chapter.index.delivery_mode

    chapter.queue_for = "bulk"
    assert_equal :at_most_once, chapter.reindex.delivery_mode

    chapter.queue_for = "editors"
    assert_equal :exactly_once, chapter.reindex.delivery_mode
  end

  test "delay passes delivery_mode" do
    job = FairyTail.delay(delivery_mode: :at_least_once).princesses

    assert_equal :at_least_once, job.delivery_mode
    assert_equal "at_least_once", stored_arguments(job)["delivery_mode"]
  end

  test "handle_asynchronously evaluates option procs on every call" do
    chapter = Chapter.new
    chapter.queue_for = "first"
    assert_equal "first", chapter.publish.queue

    chapter.queue_for = "second"
    assert_equal "second", chapter.publish.queue
  end

  test "delay creates a new PerformableMethod job" do
    assert_difference -> { queued_jobs.size }, 1 do
      job = "hello".delay.count("l")

      assert_equal Delayed::PerformableMethod, job.payload_object.class
      assert_equal :count, job.payload_object.method_name
      assert_equal [ "l" ], job.payload_object.args
    end
  end

  test "__delay__ is an alias of delay" do
    job = "hello".__delay__(priority: 3).count("l")

    assert_equal :count, job.payload_object.method_name
    assert_equal 3, job.priority
  end

  test "delay sets default priority" do
    Delayed::Worker.default_priority = 99

    assert_equal 99, FairyTail.delay.to_s.priority
  end

  test "delay sets default queue name" do
    Delayed::Worker.default_queue_name = "abbazabba"

    assert_equal "abbazabba", FairyTail.delay.to_s.queue
  end

  test "delay sets job options" do
    run_at = Time.parse("2010-05-03 12:55 AM")

    job = FairyTail.delay(priority: 20, run_at: run_at).to_s

    assert_equal run_at, job.run_at
    assert_equal 20, job.priority
  end

  test "delay stores the job in the requested queue with its priority" do
    job = FairyTail.delay(queue: "tales", priority: 4).princesses

    assert_equal [ "tales", 4 ], [ job.queue, job.priority ]
    stored = stored_job(job)
    assert_equal "tales", stored.queue_name
    assert_equal 4, stored.priority
    assert_equal "Delayed::JobWrapper", stored.class_name
  end

  test "delayed calls on plain objects run later with their state" do
    StatefulJob.performed = []
    StatefulJob.new("plain", 2, { "key" => :value }).delay.perform

    assert_empty StatefulJob.performed
    perform_ready_jobs
    assert_equal [ [ "plain", 2, { "key" => :value } ] ], StatefulJob.performed
  end

  test "does not delay the job when delay_jobs is false" do
    Delayed::Worker.delay_jobs = false
    fairy_tail = FairyTail.new

    assert_no_difference -> { queued_jobs.size } do
      fairy_tail.delay.tell
    end
    assert_equal true, fairy_tail.happy_ending
  end

  test "does delay the job when delay_jobs is true" do
    Delayed::Worker.delay_jobs = true
    fairy_tail = FairyTail.new

    assert_difference -> { queued_jobs.size }, 1 do
      fairy_tail.delay.tell
    end
    assert_nil fairy_tail.happy_ending
  end

  test "does delay when delay_jobs is a proc returning true" do
    Delayed::Worker.delay_jobs = ->(_job) { true }
    fairy_tail = FairyTail.new

    assert_difference -> { queued_jobs.size }, 1 do
      fairy_tail.delay.tell
    end
    assert_nil fairy_tail.happy_ending
  end

  test "does not delay the job when delay_jobs is a proc returning false" do
    Delayed::Worker.delay_jobs = ->(_job) { false }
    fairy_tail = FairyTail.new

    assert_no_difference -> { queued_jobs.size } do
      fairy_tail.delay.tell
    end
    assert_equal true, fairy_tail.happy_ending
  end

  test "send_later is deprecated and delays the method" do
    job = nil

    assert_output(nil, "[DEPRECATION] `object.send_later(:method)` is deprecated. Use `object.delay.method\n") do
      job = "hello".send_later(:count, "l")
    end
    assert_equal :count, job.payload_object.method_name
    assert_equal [ "l" ], job.payload_object.args
  end

  test "send_at is deprecated and delays the method until the given time" do
    run_at = 1.day.from_now.change(usec: 0)
    job = nil

    assert_output(nil, "[DEPRECATION] `object.send_at(time, :method)` is deprecated. Use `object.delay(:run_at => time).method\n") do
      job = "hello".send_at(run_at, :count, "l")
    end
    assert_equal run_at, job.run_at
    assert_equal [ "l" ], job.payload_object.args
  end

  test "DelayProxy sends every call to the enqueue path, even BasicObject methods" do
    job = Delayed::DelayProxy.new(Delayed::PerformableMethod, "hello", {}) == "hello"

    assert_equal :==, job.payload_object.method_name
    assert_equal [ "hello" ], job.payload_object.args
  end

  test "DelayProxy can raise" do
    proxy = Delayed::DelayProxy.new(Delayed::PerformableMethod, "hello", {})

    error = assert_raises(ArgumentError) { proxy.raise(ArgumentError, "proxied") }
    assert_equal "proxied", error.message
  end

  test "DelayProxy raises NoMethodError when the target does not respond to the method" do
    assert_raises(NoMethodError) { "hello".delay.no_such_method }
    assert_empty queued_jobs
  end
end
