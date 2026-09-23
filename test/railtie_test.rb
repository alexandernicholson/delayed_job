# frozen_string_literal: true

require "test_helper"
require "rake"

class RailtieTest < ActiveSupport::TestCase
  include OpsTestHelper

  test "the railtie is registered with the application" do
    assert_includes Rails.application.railties.map(&:class), Delayed::Railtie
  end

  test "rake_tasks loads the delayed_job tasks" do
    app = Rake::Application.new
    Rake.with_application(app) do
      Delayed::Railtie.instance.send(:run_tasks_blocks, Rails.application)
    end
    %w[ jobs:clear jobs:work jobs:workoff jobs:check jobs:environment_options jobs:import ].each do |name|
      assert app.tasks.map(&:name).include?(name), "expected #{name} to be defined"
    end
  end

  test "the logger initializer sets Delayed::Worker.logger to Rails.logger when unset" do
    Delayed::Worker.stubs(:logger).returns(nil)
    Delayed::Worker.expects(:logger=).with(Rails.logger)
    run_initializer("delayed_job.logger")
  end

  test "the logger initializer keeps an existing logger" do
    Delayed::Worker.stubs(:logger).returns(Logger.new(nil))
    Delayed::Worker.expects(:logger=).never
    run_initializer("delayed_job.logger")
  end

  test "the logger initializer tolerates a Delayed::Worker without a logger" do
    skip "Delayed::Worker has a logger" if Delayed::Worker.respond_to?(:logger=)
    assert_nothing_raised { run_initializer("delayed_job.logger") }
  end

  test "the active_job initializer loads the Solid Queue delayed_job adapter" do
    run_initializer("delayed_job.active_job")
    assert_operator ActiveJob::QueueAdapters::DelayedJobAdapter, :<, ActiveJob::QueueAdapters::SolidQueueAdapter
  end

  private
    def run_initializer(name)
      Delayed::Railtie.initializers.find { |initializer| initializer.name == name }.run(Rails.application)
    end
end
