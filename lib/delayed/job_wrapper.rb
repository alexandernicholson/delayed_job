# frozen_string_literal: true

module Delayed
  class JobWrapper < ActiveJob::Base
    include RetryPolicy
    include ActiveJob::RunTimeLimit

    self.log_arguments = false

    attr_accessor :locked_at, :locked_by, :failed_at, :last_error
    attr_writer :run_at, :attempts
    attr_reader :error

    class << self
      def enqueue_payload(payload_object, options = {})
        new(payload_object).tap do |job|
          job.send(:apply_options, options)
          Delayed::Worker.lifecycle.run_callbacks(:enqueue, job) do
            job.hook(:enqueue)
            Delayed::Worker.delay_job?(job) ? instrument(:enqueue, job) { job.save } : job.invoke_job
          end
        end
      end

      def sync_worker_settings
        sync_run_time_limit
        sync_process_death_attempts
      end

      def sync_run_time_limit
        max_run_time = Delayed::Worker.max_run_time
        self.run_time_limit = (max_run_time if max_run_time.is_a?(Numeric) && max_run_time.positive?)
      end

      def sync_process_death_attempts
        return unless respond_to?(:retries_on_process_death)

        attempts = Delayed::Worker.max_attempts
        if attempts.is_a?(Integer) && attempts.positive?
          retries_on_process_death(attempts: attempts)
        elsif respond_to?(:process_death_attempts=)
          self.process_death_attempts = nil
        end
      end

      def instrument(event, job, **extra, &block)
        ActiveSupport::Notifications.instrument("#{event}.delayed_job", event_payload(job).merge(extra), &block)
      end

      def event_payload(job)
        {
          display_name: job.name,
          job_id: job.respond_to?(:job_id) ? job.job_id : job.id,
          queue: job.queue,
          priority: job.priority,
          attempts: job.attempts
        }
      end
    end

    def perform(*)
      worker = Delayed::Worker.current
      self.locked_at = Time.current
      self.locked_by = worker.name
      @performing = true
      @fail_in_solid_queue = false

      self.class.instrument(:perform, self) do |payload|
        result = Delayed::Worker.lifecycle.run_callbacks(:perform, worker, self) { worker.run(self) }
        payload[:success] = result == true
        worker.send(:handled_failure) unless result == true || @fail_in_solid_queue
      end

      raise failure_error if @fail_in_solid_queue
    ensure
      @performing = false
    end

    def serialize
      super.tap { |job_data| job_data["delivery_mode"] = @delivery_mode_option.to_s if @delivery_mode_option }
    end

    def deserialize(job_data)
      super
      @serialized_payload = Array(job_data["arguments"]).first
      @attempts = executions.to_i
      @delivery_mode_option = job_data["delivery_mode"]&.to_sym
    end

    def delivery_mode
      @delivery_mode_option || payload_delivery_mode || Delayed::Worker.delivery_mode
    end

    def payload_object
      deserialize_arguments_if_needed
      raise DeserializationError, "Job failed to load: #{(@payload_error.cause || @payload_error).message}. Handler: #{handler.inspect}" if @payload_error

      arguments.first
    end

    def payload_object=(object)
      @name = nil
      @payload_error = nil
      @serialized_payload = nil
      self.serialized_arguments = nil
      self.arguments = [ object ]
    end

    def handler
      ActiveSupport::JSON.encode(serialized_payload)
    end

    def name
      @name ||= payload_object.respond_to?(:display_name) ? payload_object.display_name : payload_object.class.name
    rescue DeserializationError
      payload_class_name
    end

    def display_name
      name
    end

    def invoke_job
      Delayed::Worker.lifecycle.run_callbacks(:invoke_job, self) do
        hook :before
        payload_object.perform
        hook :success
      rescue Exception => e
        hook :error, e
        raise e
      ensure
        hook :after
      end
    end

    def hook(name, *)
      if payload_object.respond_to?(name)
        method = payload_object.method(name)
        method.arity.zero? ? method.call : method.call(self, *)
      end
    rescue DeserializationError
    end

    def id
      provider_job_id
    end

    def queue
      queue_name
    end

    def queue=(queue)
      self.queue_name = queue.to_s
    end

    def run_at
      @run_at ||= scheduled_at && (scheduled_at.is_a?(Numeric) ? Time.zone.at(scheduled_at) : scheduled_at)
    end

    def attempts
      @attempts ||= 0
    end

    def error=(error)
      @error = error
      self.last_error = "#{error.message}\n#{Array(error.backtrace).join("\n")}"
    end

    def failed?
      !!failed_at
    end
    alias_method :failed, :failed?

    def unlock
      self.locked_at = nil
      self.locked_by = nil
    end

    def performing?
      !!@performing
    end

    def solid_queue_run_time_limit
      return unless performing? && provider_job_id.present?

      [ self.class.run_time_limit, ::SolidQueue.max_run_time ].compact.min
    end

    def save
      save!
    rescue ActiveJob::EnqueueError
      false
    end

    def save!
      discard_stored_copies unless performing? || provider_job_id.nil?
      self.run_at ||= Time.current
      self.executions = attempts
      delivery_mode
      enqueue(wait_until: run_at)
      raise enqueue_error || ActiveJob::EnqueueError.new("#{self.class.name} could not be enqueued") unless successfully_enqueued?

      true
    end

    def destroy
      discard_stored_copies unless performing?
      self
    end

    def fail!
      self.failed_at = Time.current
      if performing?
        @fail_in_solid_queue = true
      else
        fail_stored_copy
      end
      true
    end

    private
      def apply_options(options)
        self.queue = options[:queue] if options[:queue]
        self.priority = options[:priority]
        self.run_at = options[:run_at]
        self.attempts = options[:attempts] if options[:attempts]
        self.job_id = options[:job_id].to_s if options[:job_id]
        @delivery_mode_option = RetryPolicy.delivery_mode!(options[:delivery_mode]) unless options[:delivery_mode].nil?
      end

      def payload_delivery_mode
        payload = payload_object
        RetryPolicy.delivery_mode!(payload.delivery_mode) if !payload.is_a?(PerformableMethod) && payload.respond_to?(:delivery_mode)
      rescue DeserializationError
        nil
      end

      def serialize_arguments(arguments)
        Serializers::ObjectSerializer.permit { super }
      end

      def deserialize_arguments(serialized_arguments)
        super
      rescue ActiveJob::DeserializationError => e
        @payload_error = e
        []
      end

      def serialized_payload
        @serialized_payload || serialize_arguments(arguments).first
      end

      def payload_class_name
        payload = serialized_payload
        return payload.class.name unless payload.is_a?(Hash)

        payload["class"] || (payload["_aj_globalid"] && GlobalID.parse(payload["_aj_globalid"])&.model_name)
      end

      def discard_stored_copies
        %i[ pending scheduled failed ].each { |status| SolidQueue::Admin.discard_job(job_id, status: status) }
      end

      def fail_stored_copy
        stored = SolidQueue::Admin.find_job(job_id)
        return if stored.nil? || stored.claimed? || stored.failed?

        if SolidQueue.mongodb?
          stored.fail_with(failure_error)
        else
          SolidQueue::Job.transaction do
            stored.ready_execution&.destroy!
            stored.scheduled_execution&.destroy!
            stored.failed_with(failure_error)
          end
        end
      end

      def failure_error
        error || RuntimeError.new("#{name} failed")
      end
  end
end
