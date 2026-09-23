# frozen_string_literal: true

require "active_job"
require "solid_queue"

module ActiveJob
  module QueueAdapters
    if const_defined?(:DelayedJobAdapter, false) &&
        (autoload?(:DelayedJobAdapter) || !(DelayedJobAdapter < SolidQueueAdapter))
      remove_const(:DelayedJobAdapter)
    end

    class DelayedJobAdapter < SolidQueueAdapter
      class JobWrapper
        attr_accessor :job_data

        def initialize(job_data)
          @job_data = job_data
        end

        def display_name
          base_name = "#{job_data["job_class"]} [#{job_data["job_id"]}] from DelayedJob(#{job_data["queue_name"]})"

          return base_name unless log_arguments?

          "#{base_name} with arguments: #{job_data["arguments"]}"
        end

        def perform
          Base.execute(job_data)
        end

        private
          def log_arguments?
            job_data["job_class"].constantize.log_arguments?
          rescue NameError
            false
          end
      end
    end
  end
end
