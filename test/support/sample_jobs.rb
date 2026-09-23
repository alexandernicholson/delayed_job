# frozen_string_literal: true

NamedJob = Struct.new(:perform)
class NamedJob
  def display_name
    "named_job"
  end
end

class SimpleJob
  cattr_accessor :runs, default: 0

  def perform
    self.class.runs += 1
  end
end

class NamedQueueJob < SimpleJob
  def queue_name
    "job_tracking"
  end
end

class ErrorJob
  cattr_accessor :runs, default: 0

  def perform
    raise "did not work"
  end
end

class CustomRescheduleJob
  cattr_accessor :runs, default: 0
  attr_reader :offset

  def initialize(offset)
    @offset = offset
  end

  def perform
    raise "did not work"
  end

  def reschedule_at(time, _attempts)
    time + offset
  end
end

class LongRunningJob
  def perform
    sleep 250
  end
end

class OnPermanentFailureJob < SimpleJob
  cattr_accessor :failed_with

  def failure
    self.class.failed_with = :failure
  end

  def max_attempts
    1
  end
end

class CallbackJob
  cattr_accessor :messages, default: []

  def enqueue(_job)
    self.class.messages << "enqueue"
  end

  def before(_job)
    self.class.messages << "before"
  end

  def perform
    self.class.messages << "perform"
  end

  def after(_job)
    self.class.messages << "after"
  end

  def success(_job)
    self.class.messages << "success"
  end

  def error(_job, error)
    self.class.messages << "error: #{error.class}"
  end

  def failure(_job)
    self.class.messages << "failure"
  end
end

class EnqueueJobMod < SimpleJob
  def enqueue(job)
    job.run_at = 20.minutes.from_now
  end
end

module M
  class ModuleJob
    cattr_accessor :runs, default: 0

    def perform
      self.class.runs += 1
    end
  end
end

class ZeroArityHookJob
  cattr_accessor :messages, default: []

  def enqueue
    self.class.messages << "enqueue"
  end

  def before
    self.class.messages << "before"
  end

  def perform
    self.class.messages << "perform"
  end

  def success
    self.class.messages << "success"
  end

  def after
    self.class.messages << "after"
  end
end

class TwoAttemptJob < ErrorJob
  def max_attempts
    2
  end
end

class KeptFailureJob < ErrorJob
  cattr_accessor :failures, default: 0

  def max_attempts
    1
  end

  def destroy_failed_jobs?
    false
  end

  def failure(_job)
    self.class.failures += 1
  end
end

class DestroyedFailureJob < KeptFailureJob
  def destroy_failed_jobs?
    true
  end
end

class FailingFailureHookJob < ErrorJob
  def max_attempts
    1
  end

  def failure
    raise "failure hook broke"
  end
end

class ShortRunTimeJob
  def perform
    sleep 5
  end

  def max_run_time
    1.second
  end
end

class StatefulJob
  cattr_accessor :performed, default: []
  attr_reader :name, :count, :options

  def initialize(name, count, options = {})
    @name = name
    @count = count
    @options = options
  end

  def perform
    self.class.performed << [ name, count, options ]
  end
end

class FailingCallbackJob < CallbackJob
  def perform
    raise "did not work"
  end
end

class AtMostOnceJob < SimpleJob
  def delivery_mode
    :at_most_once
  end
end

class PlainActiveJob < ActiveJob::Base
  def perform; end
end

class SideEffectJob < ActiveJob::Base
  def perform; end
end

class EnqueueThenFailJob
  def perform
    SideEffectJob.perform_later
    raise "did not work"
  end
end

class EnqueueThenSucceedJob
  def perform
    SideEffectJob.perform_later
  end
end

class EnqueueOnErrorJob < ErrorJob
  def error(_job, _error)
    SideEffectJob.perform_later
  end
end
