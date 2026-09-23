# frozen_string_literal: true

require "active_support"
require "global_id"

module Delayed
  module MongoidGlobalID
    def self.install
      return unless defined?(::Mongoid::Document)
      return if ::Mongoid::Document.include?(::GlobalID::Identification)

      ::Mongoid::Document.include(::GlobalID::Identification)
    end
  end
end

Delayed::MongoidGlobalID.install
ActiveSupport.on_load(:active_job) { Delayed::MongoidGlobalID.install }
ActiveSupport.on_load(:after_initialize) { Delayed::MongoidGlobalID.install }
