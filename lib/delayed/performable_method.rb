# frozen_string_literal: true

require "active_job"
require "delayed/mongoid"

module Delayed
  class PerformableMethod
    attr_accessor :object, :method_name, :args

    def initialize(object, method_name, args)
      raise NoMethodError, "undefined method `#{method_name}' for #{object.inspect}" unless object.respond_to?(method_name, true)

      raise(ArgumentError, "job cannot be created for non-persisted record: #{object.inspect}") if object.respond_to?(:persisted?) && !object.persisted?

      self.object = object
      self.args = args
      self.method_name = method_name.to_sym
    end

    def display_name
      if object.is_a?(Class)
        "#{object}.#{method_name}"
      else
        "#{object.class}##{method_name}"
      end
    end

    def perform
      object.send(method_name, *args) if object
    end

    def method(sym)
      object.method(sym)
    end

    def method_missing(symbol, *)
      object.send(symbol, *)
    end

    def respond_to_missing?(symbol, include_private = false)
      object.respond_to?(symbol, include_private)
    end
  end

  module Serializers
    class ModuleSerializer < ActiveJob::Serializers::ObjectSerializer
      def serialize(constant)
        raise ActiveJob::SerializationError, "Serializing an anonymous class is not supported" unless constant.name

        super("value" => constant.name)
      end

      def deserialize(hash)
        hash["value"].constantize
      end

      def klass
        Module
      end
    end

    class ObjectSerializer < ActiveJob::Serializers::ObjectSerializer
      STATE_CLASSES = [ Object, BasicObject, Struct, Data ].freeze
      Unindexed = Class.new

      class << self
        def permit
          previous = ActiveSupport::IsolatedExecutionState[:delayed_job_object_serializer]
          ActiveSupport::IsolatedExecutionState[:delayed_job_object_serializer] = true
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[:delayed_job_object_serializer] = previous
        end

        def permitted?
          ActiveSupport::IsolatedExecutionState[:delayed_job_object_serializer] == true
        end
      end

      def serialize?(argument)
        self.class.permitted? && ruby_defined?(argument.class) && !claimed_elsewhere?(argument)
      end

      def serialize(object)
        raise ActiveJob::SerializationError, "Unsupported argument type: #{object.class.name}" unless serialize?(object)

        super(
          "class" => object.class.name,
          "members" => ActiveJob::Arguments.serialize(members_of(object)),
          "ivars" => object.instance_variables.to_h { |name| [ name.to_s, ActiveJob::Arguments.serialize([ object.instance_variable_get(name) ]).first ] }
        )
      end

      def deserialize(hash)
        object_class = hash["class"].safe_constantize
        raise ArgumentError, "#{hash["class"]} is not a serializable class" unless object_class.is_a?(Class) && ruby_defined?(object_class)

        members = ActiveJob::Arguments.deserialize(hash["members"])
        instantiate(object_class, members).tap do |object|
          hash["ivars"].each { |name, value| object.instance_variable_set(name, ActiveJob::Arguments.deserialize([ value ]).first) }
        end
      end

      def klass
        Unindexed
      end

      private
        def ruby_defined?(object_class)
          (object_class.ancestors.grep(Class) - STATE_CLASSES).all? do |ancestor|
            location = ancestor.name && Object.const_source_location(ancestor.name)
            location.present? && location.first != "ruby"
          end
        rescue NameError
          false
        end

        def members_of(object)
          case object
          when Struct then object.to_a
          when Data then [ object.to_h ]
          else []
          end
        end

        def instantiate(object_class, members)
          if object_class <= Data
            object_class.new(**members.first)
          else
            object_class.allocate.tap do |object|
              members.each_with_index { |value, index| object[index] = value } if object.is_a?(Struct)
            end
          end
        end

        def claimed_elsewhere?(argument)
          ActiveJob::Serializers.serializers.any? { |serializer| !own_entry?(serializer) && serializer.serialize?(argument) }
        end

        def own_entry?(serializer)
          serializer.equal?(self) || serializer.equal?(self.class)
        end
    end
  end

  class PerformableMethodSerializer < ActiveJob::Serializers::ObjectSerializer
    def serialize(performable)
      super(
        "class" => performable.class.name,
        "object" => serialize_object(performable.object),
        "method_name" => performable.method_name.to_s,
        "args" => ActiveJob::Arguments.serialize([ performable.args ]).first
      )
    end

    def deserialize(hash)
      performable_class = hash["class"].safe_constantize
      raise ArgumentError, "#{hash["class"]} is not a Delayed::PerformableMethod" unless performable_class.is_a?(Class) && performable_class <= PerformableMethod

      performable_class.allocate.tap do |performable|
        performable.object = ActiveJob::Arguments.deserialize([ hash["object"] ]).first
        performable.method_name = hash["method_name"].to_sym
        performable.args = ActiveJob::Arguments.deserialize([ hash["args"] ]).first
      end
    end

    def klass
      PerformableMethod
    end

    private
      def serialize_object(object)
        if object.is_a?(Module)
          Serializers::ModuleSerializer.serialize(object)
        else
          ActiveJob::Arguments.serialize([ object ]).first
        end
      end
  end

  ActiveJob::Serializers.add_serializers(PerformableMethodSerializer)
  ActiveJob::Serializers.add_serializers(Serializers::ObjectSerializer)
end
