# frozen_string_literal: true

module Delayed
  module Plugins
    class ClearLocks < Plugin
      callbacks do |lifecycle|
        lifecycle.around(:execute) do |worker, &block|
          block.call(worker)
        ensure
          Delayed::Job.clear_locks!(worker.name) if Delayed::Job.respond_to?(:clear_locks!)
        end
      end
    end
  end
end
