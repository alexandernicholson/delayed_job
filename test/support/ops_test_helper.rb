# frozen_string_literal: true

require "active_support/testing/time_helpers"

class OpsActiveJob < ActiveJob::Base
  cattr_accessor :performed, default: []

  queue_as :ops

  def perform(*args)
    self.class.performed << args
  end
end

class OpsFailingActiveJob < ActiveJob::Base
  def perform
    raise ArgumentError, "ops failure"
  end
end

OpsWorker = Struct.new(:name, :read_ahead) do
  def initialize(name = "host:ops pid:#{Process.pid}", read_ahead = 5)
    super
  end
end

module OpsTestHelper
  extend ActiveSupport::Concern

  include ActiveSupport::Testing::TimeHelpers

  included do
    setup do
      OpsActiveJob.performed = []
      @ops_original_adapter = ActiveJob::Base.queue_adapter
    end

    teardown do
      ActiveJob::Base.queue_adapter = @ops_original_adapter
      travel_back
      Delayed::Job.send(:heartbeats).keys.each { |process_id| Delayed::Job.send(:stop_heartbeat, process_id) }
    end
  end

  private
    def ops_process(name = "ops-runner")
      SolidQueue::Process.register(kind: "Worker", name: name, pid: Process.pid, hostname: "ops")
    end

    def ops_perform_ready_jobs(limit: 100)
      process = ops_process("ops-runner-#{SecureRandom.hex(4)}")
      limit.times do
        execution = SolidQueue::ReadyExecution.claim("*", 1, process.id).first
        break unless execution

        begin
          execution.perform
        rescue StandardError
          nil
        end
      end
    end

    def ops_solid_queue_jobs
      SolidQueue::Admin::STATUS_MAP.keys.flat_map { |status| SolidQueue::Admin.jobs(status: status) }
    end

    def ops_unfinished_count
      (SolidQueue::Admin::STATUS_MAP.keys - [ :finished ]).sum { |status| SolidQueue::Admin.jobs_count(status: status) }
    end

    def ops_enqueue(job_class = OpsActiveJob, *args, **options)
      job_class.set(**options).perform_later(*args)
    end

    def ops_worker_setting(name, value)
      Delayed::Worker.stubs(name).returns(value)
    end





    def skip_unless_story!
      skip "needs the Active Record Story model (SQL backend)" unless BACKEND == :active_record
    end
end
