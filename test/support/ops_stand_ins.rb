# frozen_string_literal: true

class OpsPayloadJob < ActiveJob::Base
  def perform(handler)
    self.class.load_payload(handler).perform
  end

  def payload_object
    self.class.load_payload(handler)
  end

  def handler
    arguments.first || Array(@serialized_arguments).first
  end

  def self.load_payload(handler)
    YAML.unsafe_load(handler)
  rescue TypeError, NameError, ArgumentError, Psych::Exception => error
    raise Delayed::DeserializationError, "Job failed to load: #{error.message}. Handler: #{handler.inspect}"
  end
end

unless Delayed::JobWrapper.respond_to?(:enqueue_payload)
  Delayed::JobWrapper.define_singleton_method(:enqueue_payload) do |payload_object, options|
    OpsPayloadJob.new(payload_object.to_yaml).tap do |job|
      job.job_id = options[:job_id] if options[:job_id]
      job.executions = options[:attempts].to_i if options[:attempts]
      job.enqueue(queue: options[:queue], priority: options[:priority], wait_until: options[:run_at])
    end
  end
end

unless Delayed::Backend::JobPreparer.method_defined?(:prepare)
  Delayed::Backend::JobPreparer.class_eval do
    attr_reader :options, :args

    def initialize(*args)
      @options = args.extract_options!.dup
      @args = args
    end

    def prepare
      options[:payload_object] ||= args.shift
      if options[:queue].nil? && options[:payload_object].respond_to?(:queue_name)
        options[:queue] = options[:payload_object].queue_name
      else
        options[:queue] ||= Delayed::Worker.try(:default_queue_name)
      end
      queue_attribute = (Delayed::Worker.try(:queue_attributes) || {}).with_indifferent_access[options[:queue]]
      options[:priority] ||= (queue_attribute && queue_attribute[:priority]) || Delayed::Worker.try(:default_priority) || 0
      if args.size > 0
        warn "[DEPRECATION] Passing multiple arguments to `#enqueue` is deprecated. Pass a hash with :priority and :run_at."
        options[:priority] = args.first || options[:priority]
        options[:run_at] = args[1]
      end
      raise ArgumentError, "Cannot enqueue items which do not respond to perform" unless options[:payload_object].respond_to?(:perform)

      options
    end
  end
end

if BACKEND == :active_record
  class OpsStory < ActiveRecord::Base
    self.table_name = "stories"

    def tell
      text
    end
  end
end
