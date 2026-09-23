# frozen_string_literal: true

module ShimTestHelper
  extend ActiveSupport::Concern

  included do
    setup do
      clear_queue
      Delayed::Worker.reset
      Delayed::Worker.delay_jobs = true
      SimpleJob.runs = 0 if defined?(SimpleJob)
    end

    teardown do
      Delayed::Worker.reset
      clear_queue
    end
  end

  private
    def clear_queue
      if SolidQueue.mongodb?
        SolidQueue::Mongo::COLLECTIONS.each { |name| SolidQueue::Mongo.collection(name).delete_many({}) }
      else
        [ SolidQueue::Job, SolidQueue::Process, SolidQueue::Semaphore, SolidQueue::Deduplication, SolidQueue::Pause,
          SolidQueue::RecurringTask, SolidQueue::Batch ].each { |model| model.delete_all if model.table_exists? }
      end
    end

    def queued_jobs
      SolidQueue::Admin.jobs(status: :pending) + SolidQueue::Admin.jobs(status: :scheduled)
    end

    def work_off(limit = 100)
      Delayed::Worker.new.work_off(limit)
    end
end
