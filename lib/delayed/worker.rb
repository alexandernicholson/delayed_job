# frozen_string_literal: true

require "timeout"
require "socket"
require "logger"
require "active_support/core_ext/kernel/reporting"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/class/attribute_accessors"
require "active_support/hash_with_indifferent_access"
require "active_support/core_ext/hash/indifferent_access"

module Delayed
  class Worker
    DEFAULT_LOG_LEVEL        = "info"
    DEFAULT_SLEEP_DELAY      = 5
    DEFAULT_MAX_ATTEMPTS     = 25
    DEFAULT_MAX_RUN_TIME     = 4.hours
    DEFAULT_DEFAULT_PRIORITY = 0
    DEFAULT_DELAY_JOBS       = true
    DEFAULT_QUEUES           = [].freeze
    DEFAULT_QUEUE_ATTRIBUTES = HashWithIndifferentAccess.new.freeze
    DEFAULT_READ_AHEAD       = 5
    DEFAULT_DELIVERY_MODE    = :exactly_once

    DELIVERY_MODES = %i[ at_least_once at_most_once exactly_once ].freeze

    DJ_BACKENDS = %i[ active_record mongoid ].freeze

    cattr_accessor :min_priority, :max_priority, :default_priority, :sleep_delay, :logger, :delay_jobs, :queues,
                   :read_ahead, :plugins, :destroy_failed_jobs, :exit_on_complete, :default_log_level

    cattr_reader :max_attempts, :max_run_time, :delivery_mode

    cattr_accessor :default_queue_name

    cattr_reader :backend, :queue_attributes

    attr_accessor :name_prefix

    class << self
      def reset
        self.default_log_level = DEFAULT_LOG_LEVEL
        self.sleep_delay       = DEFAULT_SLEEP_DELAY
        self.max_attempts      = DEFAULT_MAX_ATTEMPTS
        self.max_run_time      = DEFAULT_MAX_RUN_TIME
        self.default_priority  = DEFAULT_DEFAULT_PRIORITY
        self.delay_jobs        = DEFAULT_DELAY_JOBS
        self.queues            = DEFAULT_QUEUES
        self.queue_attributes  = DEFAULT_QUEUE_ATTRIBUTES
        self.read_ahead        = DEFAULT_READ_AHEAD
        self.delivery_mode     = DEFAULT_DELIVERY_MODE
        @lifecycle             = nil
      end

      def max_attempts=(attempts)
        @@max_attempts = attempts
        JobWrapper.sync_process_death_attempts
      end

      def max_run_time=(run_time)
        @@max_run_time = run_time
        JobWrapper.sync_run_time_limit
      end

      def delivery_mode=(mode)
        @@delivery_mode = RetryPolicy.delivery_mode!(mode)
      end

      def backend=(backend)
        if backend.is_a?(Symbol)
          if DJ_BACKENDS.include?(backend)
            warn "[DEPRECATION] Delayed::Worker.backend = :#{backend} is deprecated. Jobs are stored by Solid Queue; use Delayed::Worker.backend = :solid_queue."
          elsif backend != :solid_queue
            raise ArgumentError, "Unknown Delayed::Worker backend :#{backend}. Use :solid_queue."
          end
          backend = Delayed::Backend::SolidQueue::Job
        end
        @@backend = backend
        silence_warnings { ::Delayed.const_set(:Job, backend) }
      end

      def queue_attributes=(val)
        @@queue_attributes = val.with_indifferent_access
      end

      def guess_backend
        warn "[DEPRECATION] guess_backend is deprecated. Please remove it from your code."
      end

      def before_fork
        unless @files_to_reopen
          @files_to_reopen = []
          ObjectSpace.each_object(File) do |file|
            @files_to_reopen << file unless file.closed?
          end
        end

        backend.before_fork if backend.respond_to?(:before_fork)
      end

      def after_fork
        Array(@files_to_reopen).each do |file|
          file.reopen file.path, "a+"
          file.sync = true
        rescue ::Exception
        end
        ::SolidQueue.after_fork!
        backend.after_fork if backend.respond_to?(:after_fork)
      end

      def lifecycle
        setup_lifecycle unless @lifecycle

        @lifecycle
      end

      def setup_lifecycle
        @lifecycle = Delayed::Lifecycle.new
        plugins.each { |klass| klass.new }
        install_solid_queue_hooks
      end

      def reload_app?
        defined?(ActionDispatch::Reloader) && Rails.application.config.cache_classes == false
      end

      def delay_job?(job)
        if delay_jobs.is_a?(Proc)
          delay_jobs.arity == 1 ? delay_jobs.call(job) : delay_jobs.call
        else
          delay_jobs
        end
      end

      def current
        ActiveSupport::IsolatedExecutionState[:delayed_job_worker] || @running || default_worker
      end

      def install_solid_queue_hooks
        return if @loop_hook && ::SolidQueue::ExecutionHooks.registered?(:around_poll)

        @loop_hook = ::SolidQueue.around_poll do |_solid_queue_worker, &block|
          Delayed::Worker.lifecycle.run_callbacks(:loop, Delayed::Worker.current) { block.call }
        end
      end

      private
        attr_writer :running

        def default_worker
          @default_worker ||= allocate.tap { |worker| worker.send(:configure, {}) }
        end
    end

    self.plugins = [ Delayed::Plugins::ClearLocks ]

    self.destroy_failed_jobs = true

    cattr_accessor :raise_signal_exceptions
    self.raise_signal_exceptions = false

    @@backend = Delayed::Backend::SolidQueue::Job

    def initialize(options = {})
      configure(options)
      self.class.setup_lifecycle
    end

    def max_attempts=(attempts)
      self.class.max_attempts = attempts
    end

    def max_run_time=(run_time)
      self.class.max_run_time = run_time
    end

    def delivery_mode=(mode)
      self.class.delivery_mode = mode
    end

    def name
      return @name unless @name.nil?

      begin
        "#{@name_prefix}host:#{Socket.gethostname} pid:#{Process.pid}"
      rescue StandardError
        "#{@name_prefix}pid:#{Process.pid}"
      end
    end

    attr_writer :name

    def start
      previous_traps = trap_signals

      say "Starting job worker"

      self.class.lifecycle.run_callbacks(:execute, self) { run_solid_queue_worker }
    ensure
      previous_traps&.each { |signal, handler| trap(signal, handler || "DEFAULT") }
    end

    def stop
      @exit = true
    end

    def stop?
      !!@exit
    end

    def work_off(num = 100)
      with_current_worker do
        successes, failures = solid_queue_work_off(num)
        [ successes - @handled_failures, failures + @handled_failures ]
      end
    end

    def run(job)
      job_say job, "RUNNING"
      runtime = realtime do
        Timeout.timeout(own_run_time_limit(job), WorkerTimeout) { job.invoke_job }
        job.destroy
      end
      job_say job, format("COMPLETED after %.4f", runtime)
      true
    rescue DeserializationError => e
      job_say job, "FAILED permanently with #{e.class.name}: #{e.message}", "error"

      job.error = e
      failed(job)
    rescue Exception => e
      e = worker_timeout_for(e)
      JobWrapper.instrument(:timeout, job, max_run_time: effective_run_time(job)) if e.is_a?(WorkerTimeout)
      self.class.lifecycle.run_callbacks(:error, self, job) { handle_failed_job(job, e) }
      false
    end

    def reschedule(job, time = nil)
      if (job.attempts += 1) < max_attempts(job)
        time ||= job.reschedule_at
        job.run_at = time
        job.unlock
        JobWrapper.instrument(:retry, job, run_at: time, error: job.error) { job.save! }
      else
        job_say job, "FAILED permanently because of #{job.attempts} consecutive failures", "error"
        failed(job)
      end
    end

    def failed(job)
      JobWrapper.instrument(:failure, job, error: job.error) do
        self.class.lifecycle.run_callbacks(:failure, self, job) do
          job.hook(:failure)
        rescue StandardError => e
          say "Error when running failure callback: #{e}", "error"
          say e.backtrace.join("\n"), "error"
        ensure
          job.destroy_failed_jobs? ? job.destroy : job.fail!
        end
      end
    end

    def job_say(job, text, level = default_log_level)
      text = "Job #{job.name} (id=#{job.id})#{say_queue(job.queue)} #{text}"
      say text, level
    end

    def say(text, level = default_log_level)
      text = "[Worker(#{name})] #{text}"
      puts text unless @quiet
      return unless (destination = logger || ::SolidQueue.logger)

      level = Logger::Severity.constants.detect { |i| Logger::Severity.const_get(i) == level }.to_s.downcase unless level.is_a?(String)
      destination.send(level, "#{Time.now.strftime("%FT%T%z")}: #{text}")
    end

    def max_attempts(job)
      job.max_attempts || self.class.max_attempts
    end

    def max_run_time(job)
      job.max_run_time || self.class.max_run_time
    end

    protected
      def say_queue(queue)
        " (queue=#{queue})" if queue
      end

      def handle_failed_job(job, error)
        job.error = error
        job_say job, "FAILED (#{job.attempts} prior attempts) with #{error.class.name}: #{error.message}", "error"
        reschedule(job)
      end

      def reload!
        return unless self.class.reload_app?

        if defined?(ActiveSupport::Reloader)
          Rails.application.reloader.reload!
        else
          ActionDispatch::Reloader.cleanup!
          ActionDispatch::Reloader.prepare!
        end
      end

    private
      def configure(options)
        @quiet = options.key?(:quiet) ? options[:quiet] : true
        @failed_reserve_count = 0
        @handled_failures = 0

        [ :min_priority, :max_priority, :sleep_delay, :read_ahead, :queues, :exit_on_complete ].each do |option|
          self.class.send("#{option}=", options[option]) if options.key?(option)
        end
      end

      def handled_failure
        @handled_failures += 1
      end

      def realtime
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      def with_current_worker
        previous = ActiveSupport::IsolatedExecutionState[:delayed_job_worker]
        ActiveSupport::IsolatedExecutionState[:delayed_job_worker] = self
        @handled_failures = 0
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[:delayed_job_worker] = previous
      end

      def trap_signals
        {
          "TERM" => trap("TERM") do
            Thread.new { say "Exiting..." }
            stop
            raise SignalException, "TERM" if self.class.raise_signal_exceptions
          end,
          "INT" => trap("INT") do
            Thread.new { say "Exiting..." }
            stop
            raise SignalException, "INT" if self.class.raise_signal_exceptions && self.class.raise_signal_exceptions != :term
          end
        }
      end

      def solid_queue_queues
        Array(self.class.queues).map(&:to_s).presence || [ "*" ]
      end

      def priority_range
        Range.new(self.class.min_priority, self.class.max_priority) if self.class.min_priority || self.class.max_priority
      end

      def solid_queue_worker_options
        {
          queues: solid_queue_queues,
          polling_interval: self.class.sleep_delay,
          threads: 1,
          min_priority: self.class.min_priority,
          max_priority: self.class.max_priority,
          exit_on_complete: (true if self.class.exit_on_complete)
        }.compact
      end

      def run_solid_queue_worker
        self.class.install_solid_queue_hooks
        self.class.send(:running=, self)
        dispatcher = start_solid_queue_process(::SolidQueue::Dispatcher.new(polling_interval: self.class.sleep_delay))
        process = start_solid_queue_process(::SolidQueue::Worker.new(**solid_queue_worker_options))
        sleep 0.1 until stop? || !process.alive?
        say "No more jobs available. Exiting" if process.drained?
      ensure
        process&.stop
        dispatcher&.stop
        self.class.send(:running=, nil)
      end

      def start_solid_queue_process(process)
        process.mode = :async
        process.start
        process
      end

      def solid_queue_work_off(num)
        result = ::SolidQueue.work_off(queues: solid_queue_queues, limit: stop? ? [ num, 1 ].min : num, priority: priority_range)
        @failed_reserve_count = 0
        result.to_a
      rescue ::SolidQueue::Processes::UnrecoverableError
        raise
      rescue StandardError => e
        reserve_failed(e)
        [ 0, 0 ]
      end

      def reserve_failed(error)
        say "Error while reserving job: #{error}"
        Delayed::Job.recover_from(error) if Delayed::Job.respond_to?(:recover_from)
        @failed_reserve_count += 1
        raise FatalBackendError if @failed_reserve_count >= 10
      end

      def effective_run_time(job)
        [ max_run_time(job), job.try(:solid_queue_run_time_limit) ].compact.min
      end

      def own_run_time_limit(job)
        limit = max_run_time(job).to_i
        covered = job.try(:solid_queue_run_time_limit)
        covered && covered.to_i <= limit ? 0 : limit
      end

      def worker_timeout_for(error)
        if error.is_a?(::SolidQueue::Processes::RunTimeExceededError)
          WorkerTimeout.new("execution expired").tap { |timeout| timeout.set_backtrace(error.backtrace) }
        else
          error
        end
      end
  end
end

Delayed::Worker.reset
Delayed::Worker.setup_lifecycle
ActiveSupport.on_load(:after_initialize) { Delayed::JobWrapper.sync_worker_settings }
