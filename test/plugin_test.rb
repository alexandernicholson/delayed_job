# frozen_string_literal: true

require "test_helper"

class PluginTest < ActiveSupport::TestCase
  test "instantiating a plugin registers its callbacks on the worker lifecycle" do
    performances = 0
    plugin = Class.new(Delayed::Plugin) do
      callbacks do |lifecycle|
        lifecycle.before(:enqueue) { performances += 1 }
      end
    end

    plugin.new
    Delayed::Worker.lifecycle.run_callbacks(:enqueue, nil) { }

    assert_equal 1, performances
  end

  test "a plugin without callbacks registers nothing" do
    assert_nothing_raised { Class.new(Delayed::Plugin).new }
  end

  test "callback blocks are kept per plugin class" do
    first = Class.new(Delayed::Plugin) { callbacks { |_lifecycle| } }
    second = Class.new(Delayed::Plugin)

    assert_not_nil first.callback_block
    assert_nil second.callback_block
  end

  test "does not double-register plugins on worker instantiation" do
    performances = 0
    plugin = Class.new(Delayed::Plugin) do
      callbacks do |lifecycle|
        lifecycle.before(:enqueue) { performances += 1 }
      end
    end
    Delayed::Worker.plugins << plugin

    Delayed::Worker.new
    Delayed::Worker.new
    Delayed::Worker.lifecycle.run_callbacks(:enqueue, nil) { }

    assert_equal 1, performances
  end

  test "ClearLocks is a default plugin" do
    assert_includes Delayed::Worker.plugins, Delayed::Plugins::ClearLocks
    assert_operator Delayed::Plugins::ClearLocks, :<, Delayed::Plugin
  end

  test "ClearLocks wraps execute and clears the worker's locks through the backend" do
    worker = Delayed::Worker.new
    worker.name = "worker-1"
    Delayed::Job.expects(:clear_locks!).with("worker-1")
    ran = nil

    Delayed::Worker.lifecycle.run_callbacks(:execute, worker) { |w| ran = w }

    assert_same worker, ran
  end

  test "ClearLocks clears locks even when the worker raises" do
    worker = Delayed::Worker.new
    Delayed::Job.expects(:clear_locks!).with(worker.name)

    assert_raises(RuntimeError) { Delayed::Worker.lifecycle.run_callbacks(:execute, worker) { raise "boom" } }
  end

  test "ClearLocks is harmless when the backend has no clear_locks!" do
    Delayed::Worker.backend = Class.new
    worker = Delayed::Worker.new

    assert_equal :ran, Delayed::Worker.lifecycle.run_callbacks(:execute, worker) { :ran }
  ensure
    Delayed::Worker.backend = :solid_queue
  end
end
