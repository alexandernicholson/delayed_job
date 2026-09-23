# frozen_string_literal: true

require "timeout"

module Delayed
  class WorkerTimeout < Timeout::Error; end
  class FatalBackendError < RuntimeError; end
end
