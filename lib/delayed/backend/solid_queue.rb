# frozen_string_literal: true

module Delayed
  module Backend
    module SolidQueue
      class Job
      end
    end
  end

  Job = Backend::SolidQueue::Job unless const_defined?(:Job, false)
end
