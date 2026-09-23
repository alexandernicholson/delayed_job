# frozen_string_literal: true

require "test_helper"
require "rake"

class TasksTest < ActiveSupport::TestCase
  include OpsTestHelper

  ENV_KEYS = %w[ MIN_PRIORITY MAX_PRIORITY QUEUES QUEUE QUIET SLEEP_DELAY READ_AHEAD BATCH_SIZE TABLE ].freeze

  setup do
    @original_rake = Rake.application
    @original_env = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |key| ENV.delete(key) }
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load "delayed/tasks.rb"
  end

  teardown do
    Rake.application = @original_rake
    ENV_KEYS.each { |key| ENV.delete(key) }
    @original_env.each { |key, value| ENV[key] = value }
  end

  test "defines the delayed_job tasks" do
    %w[ jobs:clear jobs:work jobs:workoff jobs:check jobs:environment_options jobs:import ].each do |name|
      assert Rake::Task.task_defined?(name), "expected #{name}"
    end
  end

  test "jobs:clear discards waiting jobs in every queue through solid_queue:clear" do
    OpsActiveJob.perform_later
    OpsActiveJob.set(queue: "other", wait: 1.hour).perform_later
    OpsFailingActiveJob.perform_later
    ops_perform_ready_jobs
    OpsActiveJob.perform_later

    out, = capture_io { Rake::Task["jobs:clear"].invoke }

    assert_equal 0, ops_unfinished_count
    assert_match "Discarded 3 jobs from all queues.", out
  end

  test "jobs:clear leaves claimed jobs to finish" do
    OpsActiveJob.perform_later
    SolidQueue::ReadyExecution.claim("*", 1, ops_process.id)
    OpsActiveJob.perform_later

    capture_io { Rake::Task["jobs:clear"].invoke }

    assert_equal 1, SolidQueue::Admin.jobs_count(status: :in_progress)
    assert_equal 0, SolidQueue::Admin.jobs_count(status: :pending)
  end

  test "jobs:clear accepts a queue" do
    OpsActiveJob.set(queue: "gone").perform_later
    OpsActiveJob.set(queue: "kept").perform_later

    out, = capture_io { Rake::Task["jobs:clear"].invoke("gone") }

    assert_equal [ "kept" ], SolidQueue::Admin.jobs(status: :pending).map(&:queue_name)
    assert_match "Discarded 1 jobs from queue gone.", out
  end

  test "jobs:clear uses an already loaded solid_queue:clear" do
    cleared = []
    Rake::Task.define_task("solid_queue:clear", [ :queue ]) { |_, args| cleared << args[:queue] }

    Rake::Task["jobs:clear"].invoke("some_queue")

    assert_equal [ "some_queue" ], cleared
    assert_equal 1, Rake::Task["solid_queue:clear"].actions.size
    assert_not Rake::Task.task_defined?("solid_queue:check_latency")
  end

  test "jobs:environment_options reads delayed_job's environment variables" do
    ENV["MIN_PRIORITY"] = "1"
    ENV["MAX_PRIORITY"] = "9"
    ENV["QUEUES"] = "a,b"
    ENV["QUIET"] = "true"
    ENV["SLEEP_DELAY"] = "3"
    ENV["READ_AHEAD"] = "7"

    assert_equal({ min_priority: "1", max_priority: "9", queues: %w[ a b ], quiet: "true", sleep_delay: 3, read_ahead: 7 }, environment_options)
  end

  test "jobs:environment_options falls back to QUEUE and defaults" do
    ENV["QUEUE"] = "single"
    assert_equal({ min_priority: nil, max_priority: nil, queues: [ "single" ], quiet: nil }, environment_options)
  end

  test "jobs:environment_options prefers QUEUES over QUEUE" do
    ENV["QUEUES"] = "many,more"
    ENV["QUEUE"] = "single"
    assert_equal %w[ many more ], environment_options[:queues]
  end

  test "jobs:work runs a Solid Queue supervisor in the foreground with the worker options" do
    ENV["QUEUES"] = "mailers"
    ENV["MIN_PRIORITY"] = "2"
    ENV["SLEEP_DELAY"] = "4"
    command = expect_command("run")
    command.expects(:daemonize)

    Rake::Task["jobs:work"].invoke

    assert_equal [ "mailers" ], @command_options[:queues]
    assert_equal "2", @command_options[:min_priority]
    assert_equal 4, @command_options[:sleep_delay]
    assert_not @command_options.key?(:exit_on_complete)
  end

  test "jobs:work maps the options onto the supervisor configuration" do
    ENV["QUEUES"] = "mailers,misc"
    ENV["MAX_PRIORITY"] = "5"
    ENV["SLEEP_DELAY"] = "4"
    SolidQueue::Supervisor.expects(:start).with do |workers:, **|
      workers == [ { queues: %w[ mailers misc ], processes: 1, threads: 1, polling_interval: 4, max_priority: 5 } ]
    end
    Dir.stubs(:chdir)

    Rake::Task["jobs:work"].invoke
  end

  test "jobs:workoff runs the supervisor with exit_on_complete" do
    command = expect_command("run")
    command.expects(:daemonize)

    Rake::Task["jobs:workoff"].invoke

    assert_equal true, @command_options[:exit_on_complete]
  end

  test "jobs:check passes when no job is waiting longer than max_age" do
    OpsActiveJob.perform_later

    out, = capture_io { Rake::Task["jobs:check"].invoke }

    assert_match "OK: no ready jobs have waited longer than 300 seconds.", out
  end

  test "jobs:check exits with an error status when ready jobs are older than max_age" do
    OpsActiveJob.perform_later
    travel 301.seconds

    _, err = capture_io do
      error = assert_raises(SystemExit) { Rake::Task["jobs:check"].invoke }
      assert_equal 1, error.status
    end
    assert_match "1 ready jobs have waited longer than 300 seconds", err
  end

  test "jobs:check accepts max_age" do
    OpsActiveJob.perform_later
    travel 61.seconds

    _, err = capture_io { assert_raises(SystemExit) { Rake::Task["jobs:check"].invoke("60") } }
    assert_match "1 ready jobs have waited longer than 60 seconds", err
  end

  test "jobs:check ignores jobs scheduled in the future and claimed jobs" do
    OpsActiveJob.set(wait: 1.hour).perform_later
    OpsActiveJob.perform_later
    SolidQueue::ReadyExecution.claim("*", 1, ops_process.id)
    travel 10.minutes

    out, = capture_io { Rake::Task["jobs:check"].invoke }
    assert_match "OK", out
  end

  test "jobs:check passes max_age to an already loaded solid_queue:check_latency" do
    checked = []
    Rake::Task.define_task("solid_queue:check_latency", [ :max_age ]) { |_, args| checked << args[:max_age] }

    Rake::Task["jobs:check"].invoke("120")
    assert_equal [ "120" ], checked
  end

  test "jobs:check defaults max_age to 300 seconds" do
    checked = []
    Rake::Task.define_task("solid_queue:check_latency", [ :max_age ]) { |_, args| checked << args[:max_age] }

    Rake::Task["jobs:check"].invoke
    assert_equal [ 300 ], checked
  end

  test "jobs:import runs Delayed::Import and prints the report" do
    result = Delayed::Import::Result.new(imported: 2, already_imported: 1, skipped_ids: [ 7 ], errors: { 7 => "boom" })
    Delayed::Import.expects(:run).with(batch_size: 100, table_name: "old_jobs").returns(result)
    ENV["BATCH_SIZE"] = "100"
    ENV["TABLE"] = "old_jobs"

    out, = capture_io { Rake::Task["jobs:import"].invoke }

    assert_match "Imported 2 delayed_jobs rows into Solid Queue (1 already imported)", out
    assert_match "Skipped 1 rows: 7", out
    assert_match "7: boom", out
  end

  test "jobs:import defaults to batches of 500 from delayed_jobs" do
    Delayed::Import.expects(:run).with(batch_size: 500, table_name: "delayed_jobs")
      .returns(Delayed::Import::Result.new(imported: 0, already_imported: 0, skipped_ids: [], errors: {}))
    out, = capture_io { Rake::Task["jobs:import"].invoke }
    assert_match "Imported 0 delayed_jobs rows", out
    assert_no_match "Skipped", out
  end

  private
    def environment_options
      Rake::Task["jobs:environment_options"].invoke
      TOPLEVEL_BINDING.receiver.instance_variable_get(:@worker_options)
    end

    def expect_command(*args)
      mock("command").tap do |command|
        Delayed::Command.expects(:new).with do |argv, options|
          @command_options = options
          argv == args
        end.returns(command)
      end
    end
end
