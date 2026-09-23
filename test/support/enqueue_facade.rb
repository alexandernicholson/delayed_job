# frozen_string_literal: true

unless Delayed::Job.respond_to?(:enqueue)
  class << Delayed::Job
    def enqueue(*args)
      enqueue_job(Delayed::Backend::JobPreparer.new(*args).prepare)
    end

    def enqueue_job(options)
      Delayed::JobWrapper.enqueue_payload(options[:payload_object], options)
    end
  end
end
