# frozen_string_literal: true

module Delayed
  module RetryPolicy
    def self.default_reschedule_at(now, attempts)
      now + (attempts**4) + 5
    end

    def self.delivery_mode!(mode)
      unless mode.respond_to?(:to_sym) && Delayed::Worker::DELIVERY_MODES.include?(mode.to_sym)
        raise ArgumentError, "Unknown delivery mode #{mode.inspect}. Use :at_least_once, :at_most_once or :exactly_once."
      end

      mode.to_sym
    end

    def self.resolve_delivery_mode(option)
      return delivery_mode!(option) unless option.nil?

      payload = begin
        yield
      rescue DeserializationError
        nil
      end
      if !payload.is_a?(PerformableMethod) && payload.respond_to?(:delivery_mode)
        delivery_mode!(payload.delivery_mode)
      else
        Delayed::Worker.delivery_mode
      end
    end

    def reschedule_at
      if payload_object.respond_to?(:reschedule_at)
        payload_object.reschedule_at(db_time_now, attempts)
      else
        RetryPolicy.default_reschedule_at(db_time_now, attempts)
      end
    end

    def max_attempts
      payload_object.max_attempts if payload_object.respond_to?(:max_attempts)
    end

    def max_run_time
      return unless payload_object.respond_to?(:max_run_time)
      return unless (run_time = payload_object.max_run_time)

      [ run_time, Delayed::Worker.max_run_time ].min
    end

    def destroy_failed_jobs?
      payload_object.respond_to?(:destroy_failed_jobs?) ? payload_object.destroy_failed_jobs? : Delayed::Worker.destroy_failed_jobs
    rescue DeserializationError
      Delayed::Worker.destroy_failed_jobs
    end

    private
      def db_time_now
        Time.current
      end
  end
end
