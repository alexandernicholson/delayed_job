# frozen_string_literal: true

module Delayed
  class Worker
    def self.reset; end

    cattr_accessor :delay_jobs
  end
end
