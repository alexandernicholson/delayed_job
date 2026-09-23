# frozen_string_literal: true

require "rails"

module Delayed
  class Railtie < Rails::Railtie
    initializer "delayed_job.active_job" do
      ActiveSupport.on_load(:active_job) do
        require_relative "../active_job/queue_adapters/delayed_job_adapter"
      end
    end

    initializer "delayed_job.logger" do
      Delayed::Railtie.assign_logger
    end

    rake_tasks do
      load "delayed/tasks.rb"
    end

    def self.assign_logger
      return unless Delayed::Worker.respond_to?(:logger=)

      Delayed::Worker.logger ||= ::Rails.logger
    end
  end
end
