# frozen_string_literal: true

module EnqueueTestHelper
  extend ActiveSupport::Concern

  WORKER_SETTINGS = %i[ min_priority max_priority destroy_failed_jobs exit_on_complete default_queue_name logger raise_signal_exceptions ].freeze

  class RecordingLogger
    attr_reader :messages

    def initialize
      @messages = []
    end

    Logger::Severity.constants.each do |severity|
      define_method(severity.to_s.downcase) { |message| @messages << [ severity.to_s.downcase, message ] }
    end
  end

  included do
    setup do
      @saved_worker_settings = WORKER_SETTINGS.index_with { |setting| Delayed::Worker.class_variable_get(:"@@#{setting}") }
      @saved_worker_plugins = Delayed::Worker.plugins.dup
      CallbackJob.messages = [] if defined?(CallbackJob)
    end

    teardown do
      @saved_worker_settings.each { |setting, value| Delayed::Worker.class_variable_set(:"@@#{setting}", value) }
      Delayed::Worker.plugins = @saved_worker_plugins
      ActiveJob::QueueAdapters::SolidQueueAdapter.stopping = false
      SolidQueue::ExecutionHooks.clear
    end
  end

  private
    def perform_ready_jobs(queues = "*")
      process = register_test_process
      performed = 0
      while (execution = SolidQueue::ReadyExecution.claim(queues, 1, process.id).first)
        begin
          execution.perform
        rescue Exception
        end
        performed += 1
      end
      performed
    ensure
      process&.deregister
    end

    def perform_due_jobs(at: Time.current)
      travel_to(at) do
        SolidQueue::ScheduledExecution.dispatch_next_batch(500)
        perform_ready_jobs
      end
    end

    def register_test_process
      SolidQueue::Process.register(kind: "Worker", name: "test-#{SecureRandom.hex(6)}", pid: ::Process.pid, hostname: "test", metadata: {})
    end

    def solid_queue_jobs(status)
      SolidQueue::Admin.jobs(status: status)
    end

    def solid_queue_job(active_job_id)
      SolidQueue::Admin.find_job(active_job_id)
    end

    def stored_job(job)
      SolidQueue::Admin.find_job(job.active_job_id)
    end

    def stored_arguments(job)
      stored_job(job).arguments
    end

    def stored_wrapper(job)
      ActiveJob::Base.deserialize(stored_arguments(job))
    end

    def failed_job_error(job)
      SolidQueue::Admin.job_attributes(stored_job(job), status: :failed)[:error].with_indifferent_access
    end

    def capture_delayed_job_events(pattern = /\.delayed_job\z/)
      events = []
      callback = ->(event) { events << event }
      ActiveSupport::Notifications.subscribed(callback, pattern, monotonic: false) { yield }
      events
    end
end

ActiveSupport::TestCase.include EnqueueTestHelper
