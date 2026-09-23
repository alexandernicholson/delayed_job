# frozen_string_literal: true

require "fileutils"
require "logger"
require "optparse"
require "pathname"

module Delayed
  class Command
    DIR_PWD = Pathname.new(Dir.pwd)
    COMMANDS = %w[start stop restart status run zap].freeze
    WORKER_SETTINGS = %i[min_priority max_priority sleep_delay read_ahead queues exit_on_complete quiet].freeze

    attr_accessor :worker_count, :worker_pools
    attr_reader :options, :args
    attr_writer :start_timeout, :stop_timeout

    def initialize(args, worker_options = {})
      @options = {
        quiet: true,
        pid_dir: "#{root}/tmp/pids",
        log_dir: "#{root}/log"
      }.merge(worker_options)

      @worker_count = 1
      @monitor = false

      @parser = OptionParser.new do |opt|
        opt.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options] start|stop|restart|run"

        opt.on("-h", "--help", "Show this message") do
          puts opt
          exit 1
        end
        opt.on("-e", "--environment=NAME", "Specifies the environment to run this delayed jobs under (test/development/production).") do |_e|
          warn "The -e/--environment option has been deprecated and has no effect. Use RAILS_ENV and see http://github.com/collectiveidea/delayed_job/issues/7"
        end
        opt.on("--min-priority N", "Minimum priority of jobs to run.") do |n|
          @options[:min_priority] = n
        end
        opt.on("--max-priority N", "Maximum priority of jobs to run.") do |n|
          @options[:max_priority] = n
        end
        opt.on("-n", "--number_of_workers=workers", "Number of unique workers to spawn") do |worker_count|
          @worker_count = worker_count.to_i rescue 1
        end
        opt.on("--pid-dir=DIR", "Specifies an alternate directory in which to store the process ids.") do |dir|
          @options[:pid_dir] = dir
        end
        opt.on("--log-dir=DIR", "Specifies an alternate directory in which to store the delayed_job log.") do |dir|
          @options[:log_dir] = dir
        end
        opt.on("-i", "--identifier=n", "A numeric identifier for the worker.") do |n|
          @options[:identifier] = n
        end
        opt.on("-m", "--monitor", "Start monitor process.") do
          @monitor = true
        end
        opt.on("--sleep-delay N", "Amount of time to sleep when no jobs are found") do |n|
          @options[:sleep_delay] = n.to_i
        end
        opt.on("--read-ahead N", "Number of jobs from the queue to consider") do |n|
          @options[:read_ahead] = n
        end
        opt.on("-p", "--prefix NAME", "String to be prefixed to worker process names") do |prefix|
          @options[:prefix] = prefix
        end
        opt.on("--queues=queues", "Specify which queue DJ must look up for jobs") do |queues|
          @options[:queues] = queues.split(",")
        end
        opt.on("--queue=queue", "Specify which queue DJ must look up for jobs") do |queue|
          @options[:queues] = queue.split(",")
        end
        opt.on("--pool=queue1[,queue2][:worker_count]", "Specify queues and number of workers for a worker pool") do |pool|
          parse_worker_pool(pool)
        end
        opt.on("--exit-on-complete", "Exit when no more jobs are available to run. This will exit if all jobs are scheduled to run in the future.") do
          @options[:exit_on_complete] = true
        end
        opt.on("--daemon-options a, b, c", Array, "options to be passed through to daemons gem") do |daemon_options|
          @daemon_options = daemon_options
        end
      end
      @args = @parser.parse!(args) + (@daemon_options || [])
      @options[:pid_dir] = File.expand_path(@options[:pid_dir].to_s)
      @options[:log_dir] = File.expand_path(@options[:log_dir].to_s)
    end

    def daemonize
      if worker_count > 1 && @options[:identifier]
        raise ArgumentError, "Cannot specify both --number-of-workers and --identifier"
      end

      command = @args.first
      if COMMANDS.include?(command)
        ActiveSupport::Notifications.instrument("command.delayed_job", command: command, pidfile: pidfile_path, pidfiles: pidfile_paths,
          supervisor: supervisor_options) do
          public_send(command)
        end
      else
        warn @parser.banner
        exit_with_error_status
      end
    end

    def supervisor_options
      supervisor_for(worker_entries)
    end

    def supervisor_units
      entries = worker_entries
      return [ [ process_name, supervisor_for(entries) ] ] unless isolate_workers?(entries)

      entries.flat_map { |entry| Array.new(entry[:processes]) { entry.merge(processes: 1) } }
        .each_with_index.map { |entry, index| [ "delayed_job.#{index}", supervisor_for([ entry ]) ] }
    end

    def process_name
      @options[:identifier] ? "delayed_job.#{@options[:identifier]}" : "delayed_job"
    end

    def pidfile_path
      pidfile_for(process_name)
    end

    def pidfile_paths
      supervisor_units.map { |name, _| pidfile_for(name) }
    end

    def start_timeout
      @start_timeout || 30
    end

    def stop_timeout
      @stop_timeout || ::SolidQueue.shutdown_timeout.to_f + 10
    end

    def run(worker_name = nil, options = {})
      units = supervisor_units
      units.one? ? run_supervisor(units.first.last) : run_in_foreground(units)
    end

    def start
      units = supervisor_units
      running = units.filter_map { |name, _| [ name, running_pid(pidfile_for(name)) ] if running_pid(pidfile_for(name)) }
      if running.any?
        running.each { |name, pid| puts "#{name}: already running [pid #{pid}]" }
        return exit_with_error_status
      end

      FileUtils.mkdir_p(@options[:pid_dir])
      Delayed::Worker.before_fork if Delayed::Worker.respond_to?(:before_fork)
      units.each { |name, configuration| start_daemon(name, configuration) }
    end

    def stop
      supervisor_units.each { |name, _| stop_pidfile(name, pidfile_for(name)) }
    end

    def restart
      stop
      start
    end

    def status
      states = supervisor_units.map do |name, _|
        pid = running_pid(pidfile_for(name))
        puts pid ? "#{name}: running [pid #{pid}]" : "#{name}: not running"
        pid
      end
      states.all? || exit_with_error_status
    end

    def zap
      supervisor_units.each do |name, _|
        delete_pidfile(pidfile_for(name))
        puts "#{name}: zapped #{pidfile_for(name)}"
      end
    end

  private
    def run_supervisor(configuration)
      Dir.chdir(root)

      if Delayed::Worker.respond_to?(:logger)
        Delayed::Worker.logger ||= Logger.new(File.join(@options[:log_dir], "delayed_job.log"))
      end

      ::SolidQueue.procline_prefix = @options[:prefix] if @options[:prefix]

      if Delayed::Worker.respond_to?(:lifecycle)
        worker = Delayed::Worker.new(worker_settings)
        Delayed::Worker.lifecycle.run_callbacks(:execute, worker) { ::SolidQueue::Supervisor.start(**configuration) }
      else
        ::SolidQueue::Supervisor.start(**configuration)
      end
    rescue StandardError => e
      warn e.message
      warn e.backtrace
      ::Rails.logger.fatal(e) if rails_logger_defined?
      exit_with_error_status
    end

    def run_in_foreground(units)
      Delayed::Worker.before_fork if Delayed::Worker.respond_to?(:before_fork)
      children = units.map do |_, configuration|
        fork do
          after_fork_hook
          run_supervisor(configuration)
          exit
        end
      end
      previous = %w[ TERM INT QUIT ].to_h { |signal| [ signal, trap(signal) { forward_signal(children, signal) } ] }
      children.each { |pid| wait_child(pid) }
    ensure
      previous&.each { |signal, handler| trap(signal, handler || "DEFAULT") }
    end

    def forward_signal(pids, signal)
      pids.each do |pid|
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def wait_child(pid)
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end

    def start_daemon(name, configuration)
      path = pidfile_for(name)
      child = fork do
        Process.daemon(true)
        after_fork_hook
        ::SolidQueue.supervisor_pidfile = path
        run_supervisor(configuration)
        exit
      end
      Process.wait(child)

      if (pid = wait_for(start_timeout) { running_pid(path) })
        puts "#{name}: process with pid #{pid} started."
      else
        warn "#{name}: failed to start within #{start_timeout} seconds, check #{File.join(@options[:log_dir], "delayed_job.log")}"
        exit_with_error_status
      end
    end

    def stop_pidfile(name, path)
      unless (pid = running_pid(path))
        puts "#{name}: not running"
        delete_pidfile(path)
        return
      end

      Process.kill(:TERM, pid)
      unless wait_for(stop_timeout) { !File.exist?(path) || !alive?(pid) }
        begin
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH
          nil
        end
      end
      delete_pidfile(path) if read_pidfile(path) == pid
      puts "#{name}: stopped [pid #{pid}]"
    end

    def supervisor_for(entries)
      { workers: entries, dispatchers: [ ::SolidQueue::Configuration::DISPATCHER_DEFAULTS.dup ] }
    end

    def isolate_workers?(entries)
      entries.any? { |entry| entry[:exit_on_complete] } && entries.sum { |entry| entry[:processes] } > 1
    end

    def pidfile_for(name)
      File.join(@options[:pid_dir], "#{name}.pid")
    end

    def worker_entries
      if worker_pools
        worker_pools.map { |queues, count| worker_entry(queues, count) }
      else
        [ worker_entry(@options[:queues], worker_count) ]
      end
    end

    def worker_entry(queues, processes)
      entry = { queues: worker_queues(queues), processes: processes, threads: 1, polling_interval: polling_interval }

      min = setting(:min_priority)
      max = setting(:max_priority)
      entry[:min_priority] = min.to_i unless min.nil?
      entry[:max_priority] = max.to_i unless max.nil?
      entry[:exit_on_complete] = true if setting(:exit_on_complete)
      entry
    end

    def worker_queues(queues)
      queues = setting_from_worker(:queues) if queues.blank?
      queues.presence || "*"
    end

    def polling_interval
      setting(:sleep_delay) || ::SolidQueue::Configuration::WORKER_DEFAULTS[:polling_interval]
    end

    def setting(name)
      @options[name].nil? ? setting_from_worker(name) : @options[name]
    end

    def setting_from_worker(name)
      Delayed::Worker.public_send(name) if Delayed::Worker.respond_to?(name)
    end

    def worker_settings
      @options.slice(*WORKER_SETTINGS)
    end

    def after_fork_hook
      if Delayed::Worker.respond_to?(:after_fork)
        Delayed::Worker.after_fork
      elsif defined?(Delayed::Job) && Delayed::Job.respond_to?(:after_fork)
        Delayed::Job.after_fork
      else
        ::SolidQueue.after_fork!
      end
    end

    def running_pid(path)
      pid = read_pidfile(path)
      pid if pid && alive?(pid)
    end

    def read_pidfile(path)
      File.read(path).strip.to_i if File.exist?(path)
    rescue Errno::ENOENT
      nil
    end

    def delete_pidfile(path)
      File.delete(path) if File.exist?(path)
    rescue Errno::ENOENT
      nil
    end

    def alive?(pid)
      return false unless pid > 0

      Process.kill(0, pid)
      true
    rescue Errno::EPERM
      true
    rescue Errno::ESRCH
      false
    end

    def wait_for(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = yield
        return result if result
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
    end

    def parse_worker_pool(pool)
      @worker_pools ||= []

      queues, worker_count = pool.split(":")
      queues = [ "*", "", nil ].include?(queues) ? [] : queues.split(",")
      worker_count = (worker_count || 1).to_i rescue 1
      @worker_pools << [ queues, worker_count ]
    end

    def root
      @root ||= rails_root_defined? ? ::Rails.root : DIR_PWD
    end

    def rails_root_defined?
      defined?(::Rails.root)
    end

    def rails_logger_defined?
      defined?(::Rails.logger)
    end

    def exit_with_error_status
      exit 1
    end
  end
end
