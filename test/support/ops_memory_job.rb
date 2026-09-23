# frozen_string_literal: true

class OpsMemoryJob
  attr_accessor :id, :priority, :attempts, :handler, :last_error, :run_at, :locked_at, :locked_by, :failed_at, :queue

  include Delayed::Backend::Base

  cattr_accessor :sequence, default: 0
  cattr_accessor :saved, default: []

  def initialize(hash = {})
    self.attempts = 0
    self.priority = 0
    self.id = (self.class.sequence += 1)
    hash.each { |key, value| public_send(:"#{key}=", value) }
  end

  def self.all
    saved
  end

  def self.count
    saved.size
  end

  def self.delete_all
    saved.clear
  end

  def self.create(attributes = {})
    new(attributes).tap(&:save)
  end

  def self.db_time_now
    Time.current
  end

  def self.find_available(worker_name, limit = 5, max_run_time = 4.hours)
    saved.select do |job|
      job.run_at <= db_time_now && !job.failed? &&
        (job.locked_at.nil? || job.locked_at < db_time_now - max_run_time || job.locked_by == worker_name)
    end.sort_by { |job| [ job.priority, job.run_at ] }.first(limit)
  end

  def lock_exclusively!(_max_run_time, worker)
    self.locked_at = self.class.db_time_now unless locked_by == worker
    self.locked_by = worker
    true
  end

  def save
    set_default_run_at
    self.class.saved << self unless self.class.saved.include?(self)
    true
  end

  def save!
    save
  end

  def destroy
    self.class.saved.delete(self)
  end

  def reload
    reset
    self
  end
end
