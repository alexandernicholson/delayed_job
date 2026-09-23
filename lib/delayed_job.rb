# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"
require "active_job"
require "solid_queue"

require "delayed/version"
require "delayed/exceptions"
require "delayed/deserialization_error"
require "delayed/compatibility"
require "delayed/lifecycle"
require "delayed/plugin"
require "delayed/plugins/clear_locks"
require "delayed/performable_method"
require "delayed/message_sending"
require "delayed/retry_policy"
require "delayed/job_wrapper"
require "delayed/backend/base"
require "delayed/backend/job_preparer"
require "delayed/backend/solid_queue"
require "delayed/worker"
require "delayed/import"
require "delayed/railtie" if defined?(Rails::Railtie)

module Delayed
  autoload :PerformableMailer, "delayed/performable_mailer"
  autoload :Command, "delayed/command"
end

ActiveSupport.on_load(:action_mailer) do
  require "delayed/performable_mailer"
  extend Delayed::DelayMail
end

Object.include Delayed::MessageSending
Module.include Delayed::MessageSendingClassMethods
