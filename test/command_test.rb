# frozen_string_literal: true

require "test_helper"
require "delayed/command"

class CommandMarkerJob < ActiveJob::Base
  def perform(path)
    File.write(path, Process.pid.to_s)
  end
end

class CommandSlowMarkerJob < ActiveJob::Base
  def perform(path)
    sleep 3
    File.write(path, Process.pid.to_s)
  end
end

class CommandTest < ActiveSupport::TestCase
  include OpsCommandHelper

  setup do
    @logger = mock("logger")
    Dir.stubs(:chdir)
    Logger.stubs(:new).returns(@logger)
    ::SolidQueue::Supervisor.stubs(:start)
    @pid_dir = File.join(TEST_ROOT, "tmp", "command-#{SecureRandom.hex(4)}")
  end

  teardown do
    FileUtils.rm_rf(@pid_dir)
  end

  test "run sets the Delayed::Worker logger" do
    Delayed::Worker.stubs(:logger).returns(nil)
    Delayed::Worker.expects(:logger=).with(@logger)
    Delayed::Command.new([]).run
  end

  test "run does not replace an existing Delayed::Worker logger" do
    Delayed::Worker.stubs(:logger).returns(Logger.new(nil))
    Delayed::Worker.expects(:logger=).never
    Delayed::Command.new([]).run
  end

  test "run starts the Solid Queue supervisor with the worker configuration" do
    command = Delayed::Command.new([])
    ::SolidQueue::Supervisor.expects(:start).with(**command.supervisor_options)
    command.run
  end

  test "run runs the supervisor in Rails.root when Rails root is defined" do
    rails_root = Pathname.new("/rails/root")
    Rails.stubs(:root).returns(rails_root)
    Dir.expects(:chdir).with(rails_root)
    Delayed::Command.new([]).run
  end

  test "run creates delayed_job.log in Rails.root/log when --log-dir is not specified" do
    Rails.stubs(:root).returns(Pathname.new("/rails/root"))
    Delayed::Worker.stubs(:logger).returns(nil)
    Delayed::Worker.stubs(:logger=)
    Logger.expects(:new).with("/rails/root/log/delayed_job.log").returns(@logger)
    Delayed::Command.new([]).run
  end

  test "run creates delayed_job.log in --log-dir when Rails root is defined" do
    Rails.stubs(:root).returns(Pathname.new("/rails/root"))
    Delayed::Worker.stubs(:logger).returns(nil)
    Delayed::Worker.stubs(:logger=)
    Logger.expects(:new).with("/custom/log/dir/delayed_job.log").returns(@logger)
    Delayed::Command.new([ "--log-dir=/custom/log/dir" ]).run
  end

  test "run runs the supervisor in $PWD when Rails root is not defined" do
    Delayed::Command.any_instance.stubs(:rails_root_defined?).returns(false)
    Dir.expects(:chdir).with(Delayed::Command::DIR_PWD)
    Delayed::Command.new([]).run
  end

  test "run creates delayed_job.log in $PWD/log when Rails root is not defined" do
    Delayed::Command.any_instance.stubs(:rails_root_defined?).returns(false)
    Delayed::Worker.stubs(:logger).returns(nil)
    Delayed::Worker.stubs(:logger=)
    Logger.expects(:new).with("#{Delayed::Command::DIR_PWD}/log/delayed_job.log").returns(@logger)
    Delayed::Command.new([]).run
  end

  test "run creates delayed_job.log in --log-dir when Rails root is not defined" do
    Delayed::Command.any_instance.stubs(:rails_root_defined?).returns(false)
    Delayed::Worker.stubs(:logger).returns(nil)
    Delayed::Worker.stubs(:logger=)
    Logger.expects(:new).with("/custom/log/dir/delayed_job.log").returns(@logger)
    Delayed::Command.new([ "--log-dir=/custom/log/dir" ]).run
  end

  test "run defaults pid and log directories under Rails.root" do
    command = Delayed::Command.new([])
    assert_equal "#{Rails.root}/tmp/pids", command.options[:pid_dir]
    assert_equal "#{Rails.root}/log", command.options[:log_dir]
    assert_equal true, command.options[:quiet]
  end

  test "run prints the error message to STDERR when an error is raised" do
    command = failing_command
    command.expects(:warn).with("An error")
    command.stubs(:warn).with(kind_of(Array))
    command.run
  end

  test "run exits with an error status when an error is raised" do
    command = failing_command
    command.expects(:exit_with_error_status)
    command.run
  end

  test "run does not use the Rails logger when it is not defined" do
    Delayed::Command.any_instance.stubs(:rails_logger_defined?).returns(false)
    Rails.logger.expects(:fatal).never
    failing_command.run
  end

  test "run logs the error to the Rails logger when it is defined" do
    rails_logger = mock("rails logger")
    Rails.stubs(:logger).returns(rails_logger)
    rails_logger.expects(:fatal).with(kind_of(test_error))
    failing_command.run
  end

  test "run wraps the supervisor in the execute lifecycle hook when available" do
    lifecycle = mock("lifecycle")
    worker = mock("worker")
    Delayed::Worker.stubs(:lifecycle).returns(lifecycle)
    Delayed::Worker.expects(:new).with({ queues: %w[a], min_priority: "1", sleep_delay: 3, quiet: true }).returns(worker)
    lifecycle.expects(:run_callbacks).with(:execute, worker).yields
    command = Delayed::Command.new(%w[--queues=a --min-priority 1 --sleep-delay 3])
    ::SolidQueue::Supervisor.expects(:start).with(**command.supervisor_options)
    command.run
  end

  test "run sets the Solid Queue procline prefix" do
    ::SolidQueue.expects(:procline_prefix=).with("app")
    Delayed::Command.new(%w[-p app]).run
  end

  test "run leaves the Solid Queue procline prefix alone without --prefix" do
    ::SolidQueue.expects(:procline_prefix=).never
    Delayed::Command.new([]).run
  end

  test "should parse --pool correctly" do
    command = Delayed::Command.new(%w[--pool=*:1 --pool=test_queue:4 --pool=mailers,misc:2])
    assert_equal [ [ [], 1 ], [ %w[test_queue], 4 ], [ %w[mailers misc], 2 ] ], command.worker_pools
  end

  test "should allow * or blank to specify any pools" do
    assert_equal [ [ [], 4 ] ], Delayed::Command.new(%w[--pool=*:4]).worker_pools
    assert_equal [ [ [], 4 ] ], Delayed::Command.new(%w[--pool=:4]).worker_pools
  end

  test "should default to one worker if not specified" do
    assert_equal [ [ %w[mailers], 1 ] ], Delayed::Command.new(%w[--pool=mailers]).worker_pools
  end

  test "worker pools become one Solid Queue worker entry per pool" do
    command = Delayed::Command.new(%w[--pool=*:1 --pool=test_queue:4 --pool=mailers,misc:2 run])
    workers = command.supervisor_options[:workers]

    assert_equal [ "*", %w[test_queue], %w[mailers misc] ], workers.map { |worker| worker[:queues] }
    assert_equal [ 1, 4, 2 ], workers.map { |worker| worker[:processes] }
    assert workers.all? { |worker| worker[:threads] == 1 }

    ::SolidQueue::Supervisor.expects(:start).with(**command.supervisor_options).once
    command.daemonize
  end

  test "supervisor options without flags" do
    options = Delayed::Command.new([]).supervisor_options
    worker = { queues: "*", processes: 1, threads: 1, polling_interval: ::SolidQueue::Configuration::WORKER_DEFAULTS[:polling_interval] }

    assert_equal [ worker ], options[:workers]
    assert_equal [ ::SolidQueue::Configuration::DISPATCHER_DEFAULTS ], options[:dispatchers]
  end

  test "--queues and --queue split on commas" do
    assert_equal %w[a b], Delayed::Command.new(%w[--queues=a,b]).options[:queues]
    assert_equal %w[c d], Delayed::Command.new(%w[--queue=c,d]).options[:queues]
    assert_equal %w[a b], Delayed::Command.new(%w[--queues=a,b]).supervisor_options[:workers].first[:queues]
  end

  test "-n sets the number of worker processes" do
    command = Delayed::Command.new(%w[-n 3])
    assert_equal 3, command.worker_count
    assert_equal 3, command.supervisor_options[:workers].first[:processes]
    assert_equal 2, Delayed::Command.new(%w[--number_of_workers=2]).supervisor_options[:workers].first[:processes]
  end

  test "--sleep-delay becomes the polling interval" do
    command = Delayed::Command.new([ "--sleep-delay", "7" ])
    assert_equal 7, command.options[:sleep_delay]
    assert_equal 7, command.supervisor_options[:workers].first[:polling_interval]
  end

  test "priorities become integer worker options" do
    command = Delayed::Command.new(%w[--min-priority 2 --max-priority 9])
    worker = command.supervisor_options[:workers].first

    assert_equal "2", command.options[:min_priority]
    assert_equal 2, worker[:min_priority]
    assert_equal 9, worker[:max_priority]
  end

  test "priorities are omitted when unset" do
    worker = Delayed::Command.new([]).supervisor_options[:workers].first
    assert_not worker.key?(:min_priority)
    assert_not worker.key?(:max_priority)
    assert_not worker.key?(:exit_on_complete)
  end

  test "--exit-on-complete is passed to the workers" do
    command = Delayed::Command.new(%w[--exit-on-complete])
    assert_equal true, command.options[:exit_on_complete]
    assert_equal true, command.supervisor_options[:workers].first[:exit_on_complete]
  end

  test "--pid-dir and -i determine the pidfile" do
    assert_equal "/pids/delayed_job.pid", Delayed::Command.new(%w[--pid-dir=/pids]).pidfile_path
    command = Delayed::Command.new(%w[--pid-dir=/pids -i 4])
    assert_equal "4", command.options[:identifier]
    assert_equal "delayed_job.4", command.process_name
    assert_equal "/pids/delayed_job.4.pid", command.pidfile_path
  end

  test "relative --pid-dir and --log-dir are expanded when the command is built" do
    command = Delayed::Command.new(%w[--pid-dir=tmp/custom --log-dir=log/custom])
    assert_equal File.join(Dir.pwd, "tmp/custom/delayed_job.pid"), command.pidfile_path
    assert_equal File.join(Dir.pwd, "log/custom"), command.options[:log_dir]
  end

  test "one supervisor runs every worker without --exit-on-complete" do
    command = Delayed::Command.new(%W[--pid-dir=#{@pid_dir} --pool=mailers:1 --pool=default:2])
    assert_equal [ [ "delayed_job", command.supervisor_options ] ], command.supervisor_units
    assert_equal [ File.join(@pid_dir, "delayed_job.pid") ], command.pidfile_paths
  end

  test "--exit-on-complete gives each worker process its own supervisor so one drained queue does not stop the others" do
    command = Delayed::Command.new(%W[--pid-dir=#{@pid_dir} --pool=mailers:1 --pool=default:2 --exit-on-complete])
    units = command.supervisor_units

    assert_equal %w[ delayed_job.0 delayed_job.1 delayed_job.2 ], units.map(&:first)
    assert_equal [ [ "mailers" ], [ "default" ], [ "default" ] ], units.map { |_, options| options[:workers].sole[:queues] }
    assert units.all? { |_, options| options[:workers].sole.values_at(:processes, :exit_on_complete) == [ 1, true ] }
    assert units.all? { |_, options| options[:dispatchers].one? }
    assert_equal %w[ delayed_job.0 delayed_job.1 delayed_job.2 ].map { |name| File.join(@pid_dir, "#{name}.pid") }, command.pidfile_paths
  end

  test "-n with --exit-on-complete names the supervisors like delayed_job's workers" do
    command = Delayed::Command.new(%W[--pid-dir=#{@pid_dir} -n 2 --exit-on-complete])
    assert_equal %w[ delayed_job.0 delayed_job.1 ], command.supervisor_units.map(&:first)
  end

  test "a single worker with --exit-on-complete keeps the delayed_job pidfile" do
    command = Delayed::Command.new(%W[--pid-dir=#{@pid_dir} --exit-on-complete])
    assert_equal [ "delayed_job" ], command.supervisor_units.map(&:first)
  end

  test "status and stop cover every supervisor pidfile" do
    write_pidfile(@pid_dir, Process.pid, name: "delayed_job.0")
    write_pidfile(@pid_dir, dead_pid, name: "delayed_job.1")
    status = Delayed::Command.new(%W[--pid-dir=#{@pid_dir} -n 2 --exit-on-complete status])
    status.expects(:exit_with_error_status)
    assert_output("delayed_job.0: running [pid #{Process.pid}]\ndelayed_job.1: not running\n") { status.daemonize }

    stop = Delayed::Command.new(%W[--pid-dir=#{@pid_dir} -n 2 --exit-on-complete stop])
    stop.expects(:stop_pidfile).with("delayed_job.0", File.join(@pid_dir, "delayed_job.0.pid"))
    stop.expects(:stop_pidfile).with("delayed_job.1", File.join(@pid_dir, "delayed_job.1.pid"))
    stop.daemonize
  end

  test "run forks one foreground supervisor per worker with --exit-on-complete" do
    command = Delayed::Command.new(%w[-n 2 --exit-on-complete run])
    command.expects(:fork).twice.returns(101, 102)
    Process.expects(:wait).with(101)
    Process.expects(:wait).with(102)
    ::SolidQueue::Supervisor.expects(:start).never
    command.daemonize
  end

  test "-e warns that it is deprecated" do
    assert_output(nil, /The -e\/--environment option has been deprecated and has no effect/) do
      Delayed::Command.new(%w[-e production])
    end
  end

  test "-m, --read-ahead, --daemon-options and extra args are accepted" do
    command = Delayed::Command.new([ "-m", "--read-ahead", "10", "--daemon-options", "a,b", "start" ])
    assert_equal "10", command.options[:read_ahead]
    assert_equal %w[start a b], command.args
  end

  test "-h prints help and exits" do
    error = nil
    out, = capture_io { error = assert_raises(SystemExit) { Delayed::Command.new(%w[-h]) } }
    assert_equal 1, error.status
    assert_match(/Usage: .* \[options\] start\|stop\|restart\|run/, out)
    assert_match(/--pool=queue1\[,queue2\]\[:worker_count\]/, out)
  end

  test "worker options can be passed without argv" do
    command = Delayed::Command.new([], queues: %w[x], min_priority: 1, max_priority: 5, sleep_delay: 2, exit_on_complete: true, quiet: false)
    worker = command.supervisor_options[:workers].first

    assert_equal false, command.options[:quiet]
    assert_equal({ queues: %w[x], processes: 1, threads: 1, polling_interval: 2, min_priority: 1, max_priority: 5, exit_on_complete: true }, worker)
  end

  test "Delayed::Worker settings are used as fallbacks" do
    Delayed::Worker.stubs(:queues).returns(%w[w])
    Delayed::Worker.stubs(:sleep_delay).returns(4)
    Delayed::Worker.stubs(:min_priority).returns(1)
    Delayed::Worker.stubs(:max_priority).returns(3)
    Delayed::Worker.stubs(:exit_on_complete).returns(true)

    worker = Delayed::Command.new([]).supervisor_options[:workers].first
    assert_equal({ queues: %w[w], processes: 1, threads: 1, polling_interval: 4, min_priority: 1, max_priority: 3, exit_on_complete: true }, worker)

    assert_equal %w[mine], Delayed::Command.new(%w[--queues=mine]).supervisor_options[:workers].first[:queues]
    assert_equal %w[w], Delayed::Command.new(%w[--pool=*:2]).supervisor_options[:workers].first[:queues]
  end

  test "empty Delayed::Worker settings fall back to Solid Queue defaults" do
    Delayed::Worker.stubs(:queues).returns([])
    Delayed::Worker.stubs(:sleep_delay).returns(nil)
    Delayed::Worker.stubs(:min_priority).returns(nil)
    Delayed::Worker.stubs(:exit_on_complete).returns(false)

    worker = Delayed::Command.new([]).supervisor_options[:workers].first
    assert_equal({ queues: "*", processes: 1, threads: 1, polling_interval: ::SolidQueue::Configuration::WORKER_DEFAULTS[:polling_interval] }, worker)
  end

  test "daemonize refuses -n with -i" do
    error = assert_raises(ArgumentError) { Delayed::Command.new(%w[-n 2 -i 1 start]).daemonize }
    assert_equal "Cannot specify both --number-of-workers and --identifier", error.message
  end

  test "daemonize without a command warns the usage and exits" do
    command = Delayed::Command.new([])
    command.expects(:warn).with(regexp_matches(/Usage: .* \[options\] start\|stop\|restart\|run/))
    command.expects(:exit_with_error_status)
    command.daemonize
  end

  test "daemonize with an unknown command warns the usage and exits" do
    command = Delayed::Command.new(%w[explode])
    command.expects(:warn).with(regexp_matches(/Usage:/))
    command.expects(:exit_with_error_status)
    ::SolidQueue::Supervisor.expects(:start).never
    command.daemonize
  end

  test "daemonize instruments the command" do
    command = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "run" ])
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("command.delayed_job") { |event| events << event.payload }
    command.daemonize

    assert_equal [ { command: "run", pidfile: File.join(@pid_dir, "delayed_job.pid"), pidfiles: [ File.join(@pid_dir, "delayed_job.pid") ],
                     supervisor: command.supervisor_options } ], events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "status on a stale pidfile reports not running" do
    write_pidfile(@pid_dir, dead_pid)
    command = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "status" ])
    command.expects(:exit_with_error_status)
    assert_output("delayed_job: not running\n") { command.daemonize }
  end

  test "status reports a live pid" do
    write_pidfile(@pid_dir, Process.pid)
    command = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "status" ])
    command.expects(:exit_with_error_status).never
    assert_output("delayed_job: running [pid #{Process.pid}]\n") { assert command.daemonize }
  end

  test "stop on a stale pidfile removes it" do
    path = write_pidfile(@pid_dir, dead_pid)
    command = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "stop" ])
    assert_output("delayed_job: not running\n") { command.daemonize }
    assert_not File.exist?(path)
  end

  test "stop terminates the pid and kills it after the timeout" do
    pid = spawn("sleep 60")
    path = write_pidfile(@pid_dir, pid)
    Process.stubs(:kill).with(0, pid).returns(1)
    Process.expects(:kill).with(:TERM, pid)
    Process.expects(:kill).with(:KILL, pid)
    command = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "stop" ])
    command.stop_timeout = 0.3
    assert_output("delayed_job: stopped [pid #{pid}]\n") { command.daemonize }
    assert_not File.exist?(path)
  ensure
    if pid
      system("kill", "-9", pid.to_s)
      Process.wait(pid)
    end
  end

  test "stop sends TERM and waits for the process to exit" do
    pid = spawn("sleep 60")
    path = write_pidfile(@pid_dir, pid)
    Thread.new { Process.wait(pid) }
    command = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "stop" ])
    assert_output("delayed_job: stopped [pid #{pid}]\n") { command.daemonize }
    assert_not process_alive?(pid)
    assert_not File.exist?(path)
  ensure
    kill_leftover(pid)
  end

  test "zap removes the pidfile" do
    path = write_pidfile(@pid_dir, dead_pid)
    assert_output("delayed_job: zapped #{path}\n") { Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "zap" ]).daemonize }
    assert_not File.exist?(path)
  end

  test "start refuses to start when already running" do
    write_pidfile(@pid_dir, Process.pid)
    command = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "start" ])
    command.expects(:exit_with_error_status)
    command.expects(:fork).never
    assert_output("delayed_job: already running [pid #{Process.pid}]\n") { command.daemonize }
  end

  test "restart stops then starts" do
    command = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "restart" ])
    sequence = sequence("restart")
    command.expects(:stop).in_sequence(sequence)
    command.expects(:start).in_sequence(sequence)
    command.daemonize
  end

  test "start, status and stop a real daemonized supervisor" do
    ::SolidQueue::Supervisor.unstub(:start)
    Dir.unstub(:chdir)
    Logger.unstub(:new)
    marker = File.join(TEST_ROOT, "tmp", "marker-#{SecureRandom.hex(4)}")
    pidfile = File.join(@pid_dir, "delayed_job.pid")

    assert_output(/delayed_job: process with pid \d+ started\./) { daemon_command("--pid-dir=#{@pid_dir}", "start").daemonize }
    pid = read_pid(pidfile)
    assert process_alive?(pid)

    status = Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "status" ])
    status.expects(:exit_with_error_status).never
    assert_output("delayed_job: running [pid #{pid}]\n") { assert status.daemonize }

    CommandMarkerJob.perform_later(marker)
    assert wait_until(timeout: 60) { File.exist?(marker) }, "the daemonized worker did not run the job"
    assert_not_equal Process.pid.to_s, File.read(marker)

    assert_output("delayed_job: stopped [pid #{pid}]\n") { Delayed::Command.new([ "--pid-dir=#{@pid_dir}", "stop" ]).daemonize }
    assert_not File.exist?(pidfile)
    assert wait_until(timeout: 30) { !process_alive?(pid) }, "the supervisor is still alive"
  ensure
    pid ||= read_pid(pidfile)
    if pid && process_alive?(pid)
      Process.kill(:TERM, pid) rescue nil
      wait_until(timeout: 20) { !process_alive?(pid) } || kill_leftover(pid)
    end
  end

  test "a real supervisor started with --exit-on-complete exits when drained" do
    ::SolidQueue::Supervisor.unstub(:start)
    Dir.unstub(:chdir)
    Logger.unstub(:new)
    marker = File.join(TEST_ROOT, "tmp", "marker-#{SecureRandom.hex(4)}")
    pidfile = File.join(@pid_dir, "delayed_job.pid")
    CommandMarkerJob.perform_later(marker)

    assert_output(/started/) { daemon_command("--pid-dir=#{@pid_dir}", "--exit-on-complete", "start").daemonize }
    pid = read_pid(pidfile)

    assert wait_until(timeout: 60) { File.exist?(marker) }
    assert wait_until(timeout: 60) { !process_alive?(pid) }
  ensure
    kill_leftover(pid)
  end

  test "real --exit-on-complete pools drain independently" do
    ::SolidQueue::Supervisor.unstub(:start)
    Dir.unstub(:chdir)
    Logger.unstub(:new)
    ::SolidQueue.stubs(:shutdown_timeout).returns(1)
    marker = File.join(TEST_ROOT, "tmp", "slow-#{SecureRandom.hex(4)}")
    CommandSlowMarkerJob.set(queue: "slow").perform_later(marker)
    pidfiles = %w[ delayed_job.0 delayed_job.1 ].map { |name| File.join(@pid_dir, "#{name}.pid") }

    assert_output(/delayed_job\.0: process with pid \d+ started\.\ndelayed_job\.1: process with pid \d+ started\./) do
      daemon_command("--pid-dir=#{@pid_dir}", "--pool=idle:1", "--pool=slow:1", "--exit-on-complete", "start").daemonize
    end
    pids = pidfiles.map { |path| read_pid(path) }

    assert wait_until(timeout: 60) { File.exist?(marker) }, "the slow pool was stopped before its job finished"
    assert wait_until(timeout: 60) { pids.none? { |pid| process_alive?(pid) } }, "the supervisors did not exit once drained"
  ensure
    Array(pids).each { |pid| kill_leftover(pid) }
  end

  private
    def test_error
      @test_error ||= Class.new(StandardError)
    end

    def failing_command
      ::SolidQueue::Supervisor.stubs(:start).raises(test_error.new("An error"))
      Delayed::Command.new([]).tap do |command|
        command.stubs(:exit_with_error_status)
        command.stubs(:warn)
      end
    end

    def daemon_command(*args)
      parent = Process.pid
      Delayed::Command.new(args).tap do |command|
        command.define_singleton_method(:exit) { |status = true| Process.pid == parent ? super(status) : Process.exit!(status) }
      end
    end
end
