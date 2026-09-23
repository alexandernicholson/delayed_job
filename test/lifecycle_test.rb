# frozen_string_literal: true

require "test_helper"

class LifecycleTest < ActiveSupport::TestCase
  setup do
    @lifecycle = Delayed::Lifecycle.new
    @calls = []
  end

  test "EVENTS lists every delayed_job event with its arguments" do
    assert_equal(
      { enqueue: [ :job ], execute: [ :worker ], loop: [ :worker ], perform: [ :worker, :job ],
        error: [ :worker, :job ], failure: [ :worker, :job ], invoke_job: [ :job ] },
      Delayed::Lifecycle::EVENTS
    )
    assert_predicate Delayed::Lifecycle::EVENTS, :frozen?
  end

  test "before callbacks run before the wrapped block with the arguments" do
    @lifecycle.before(:execute) { |*args| @calls << [ :before, args ] }

    @lifecycle.run_callbacks(:execute, 1) { @calls << :inside }

    assert_equal [ [ :before, [ 1 ] ], :inside ], @calls
  end

  test "after callbacks run after the wrapped block with the arguments" do
    @lifecycle.after(:execute) { |*args| @calls << [ :after, args ] }

    @lifecycle.run_callbacks(:execute, 1) { @calls << :inside }

    assert_equal [ :inside, [ :after, [ 1 ] ] ], @calls
  end

  test "around callbacks wrap the block" do
    @lifecycle.around(:execute) do |*args, &block|
      @calls << :before!
      block.call(*args)
      @calls << :after!
    end

    @lifecycle.run_callbacks(:execute, 1) { |*args| @calls << [ :inside, args ] }

    assert_equal [ :before!, [ :inside, [ 1 ] ], :after! ], @calls
  end

  test "multiple around callbacks run in registration order" do
    @lifecycle.around(:execute) do |*args, &block|
      @calls << :before!
      block.call(*args)
      @calls << :after!
    end
    %i[ one two three ].each do |name|
      @lifecycle.around(:execute) do |*args, &block|
        @calls << name
        block.call(*args)
      end
    end

    @lifecycle.run_callbacks(:execute, 1) { @calls << :inside }

    assert_equal %i[ before! one two three inside after! ], @calls
  end

  test "run_callbacks returns the block result" do
    @lifecycle.before(:execute) { }

    assert_equal :result, @lifecycle.run_callbacks(:execute, 1) { :result }
  end

  test "after callbacks do not run when the block raises" do
    @lifecycle.after(:execute) { @calls << :after }

    assert_raises(RuntimeError) { @lifecycle.run_callbacks(:execute, 1) { raise "boom" } }
    assert_empty @calls
  end

  test "raises if callback is executed with wrong number of parameters" do
    @lifecycle.before(:execute) { }

    error = assert_raises(ArgumentError) { @lifecycle.run_callbacks(:execute, 1, 2, 3) { } }
    assert_equal "Callback execute expects 1 parameter(s): worker", error.message
  end

  test "raises InvalidCallback for unknown events" do
    error = assert_raises(Delayed::InvalidCallback) { @lifecycle.before(:bogus) { } }
    assert_equal "Unknown callback event: bogus", error.message

    assert_raises(Delayed::InvalidCallback) { @lifecycle.run_callbacks(:bogus) { } }
  end

  test "Callback raises InvalidCallback for unknown callback types" do
    error = assert_raises(Delayed::InvalidCallback) { Delayed::Callback.new.add(:sideways) { } }
    assert_equal "Invalid callback type: sideways", error.message
  end

  test "Callback executes before, around and after in order" do
    callback = Delayed::Callback.new
    callback.add(:before) { |value| @calls << [ :before, value ] }
    callback.add(:after) { |value| @calls << [ :after, value ] }
    callback.add(:around) do |value, &block|
      @calls << :around
      block.call(value * 2)
    end

    result = callback.execute(1) do |value|
      @calls << [ :inside, value ]
      :done
    end

    assert_equal :done, result
    assert_equal [ [ :before, 1 ], :around, [ :inside, 2 ], [ :after, 1 ] ], @calls
  end
end
