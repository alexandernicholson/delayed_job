# frozen_string_literal: true

require "psych"

module Delayed
  module Backend
    module Base
      DEFAULT_MAX_RUN_TIME = 4.hours

      def self.included(base)
        base.extend ClassMethods
      end

      def self.worker_setting(name, default = nil)
        Delayed::Worker.respond_to?(name) ? Delayed::Worker.public_send(name) : default
      end

      def self.run_lifecycle(event, *args, &block)
        if Delayed::Worker.respond_to?(:lifecycle)
          Delayed::Worker.lifecycle.run_callbacks(event, *args, &block)
        else
          block.call(*args)
        end
      end

      module HandlerLoader
        DEFAULT_PERMITTED_CLASSES = %w[
          Symbol Time Date DateTime BigDecimal Range Set
          ActiveSupport::HashWithIndifferentAccess ActiveSupport::TimeWithZone ActiveSupport::TimeZone ActiveSupport::Duration
          Delayed::PerformableMethod Delayed::PerformableMailer
          ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper
        ].freeze

        mattr_accessor :permitted_classes, default: []

        def self.load(yaml, permitted_classes: [])
          document = Psych.parse(yaml.to_s)
          return unless document

          names = (DEFAULT_PERMITTED_CLASSES + self.permitted_classes + permitted_classes).map(&:to_s)
          class_loader = Psych::ClassLoader::Restricted.new(names, [])
          Visitor.new(Psych::ScalarScanner.new(class_loader), class_loader).accept(document)
        end

        class Visitor < Psych::Visitors::ToRuby
          RECORD_TAG = %r{\A!ruby/(ActiveRecord|Mongoid):(.+)\z}
          OBJECT_TAG = %r{\A!ruby/object:(.+)\z}
          REFERENCE_TAG = %r{\A!ruby/(class|module)\z}
          PERFORMABLE_TAG = %r{\A!ruby/[\w-]+:(Delayed::Performable(?:Method|Mailer))\z}
          PERFORMABLE_CLASSES = %w[ Delayed::PerformableMethod Delayed::PerformableMailer ].freeze
          UNSAFE_RECEIVERS = %w[
            Kernel Object BasicObject Module Class Process Signal IO File Dir FileUtils ObjectSpace Marshal Psych YAML
            Binding Method UnboundMethod Proc Thread Fiber Ractor GC RubyVM Open3 Etc
          ].freeze
          UNSAFE_METHODS = %i[
            send __send__ public_send instance_eval instance_exec class_eval class_exec module_eval module_exec eval
            system exec spawn ` fork syscall open load require require_relative autoload const_get const_set remove_const
            define_method define_singleton_method instance_variable_get instance_variable_set method public_method
            singleton_method exit exit! abort tap then yield_self constantize safe_constantize
          ].freeze
          CORE_OWNERS = [ ::Kernel, ::BasicObject, ::Object, ::Module, ::Class ].freeze

          def visit_Psych_Nodes_Scalar(node)
            refuse_performable_tag!(node)
            if REFERENCE_TAG.match?(node.tag)
              register(node, node.value.constantize)
            else
              super
            end
          end

          def visit_Psych_Nodes_Sequence(node)
            refuse_performable_tag!(node)
            super
          end

          def visit_Psych_Nodes_Mapping(node)
            case node.tag
            when RECORD_TAG
              klass = Regexp.last_match(2).constantize
              raise ArgumentError, "#{klass} is not an Active Record model or Mongoid document" unless record_class?(klass)

              find_record(klass, node)
            when OBJECT_TAG
              class_name = Regexp.last_match(1)
              if PERFORMABLE_CLASSES.include?(class_name)
                build_performable(class_name.constantize, node)
              elsif record_class?(klass = class_name.safe_constantize)
                find_record(klass, node)
              else
                super
              end
            else
              refuse_performable_tag!(node)
              super
            end
          end

          private
            def build_performable(klass, node)
              attributes = revive_hash({}, node)
              object = attributes["object"]
              method_name = attributes["method_name"]
              raise ArgumentError, "#{klass} method_name must be a String or Symbol" unless method_name.is_a?(String) || method_name.is_a?(Symbol)
              raise ArgumentError, "#{klass} may not call #{method_name} on #{object.inspect}" if unsafe_call?(object, method_name.to_sym)

              register(node, klass.new(object, method_name, attributes["args"] || []))
            end

            def unsafe_call?(object, method_name)
              return true if UNSAFE_METHODS.include?(method_name)
              return true if object.is_a?(Module) && (UNSAFE_RECEIVERS.include?(object.name) || (object.is_a?(Class) && object <= ::IO))
              return true unless object.respond_to?(method_name, !object.is_a?(Module))

              owner = object.method(method_name).owner
              core = CORE_OWNERS.any? { |mod| owner == mod || owner == mod.singleton_class }
              core && !(object.is_a?(Class) && method_name == :new)
            rescue NameError
              false
            end

            def refuse_performable_tag!(node)
              raise ArgumentError, "#{node.tag} documents can not be loaded; use !ruby/object" if node.tag && PERFORMABLE_TAG.match?(node.tag)
            end

            def record_class?(klass)
              return false unless klass.is_a?(Class)

              (defined?(::ActiveRecord::Base) && klass < ::ActiveRecord::Base) ||
                (defined?(::Mongoid::Document) && klass.include?(::Mongoid::Document))
            end

            def find_record(klass, node)
              key = klass.respond_to?(:primary_key) && klass.primary_key ? klass.primary_key.to_s : "_id"
              id = primary_key_value(node, key)
              register(node, klass.respond_to?(:unscoped) ? klass.unscoped.find(id) : klass.find(id))
            rescue StandardError => error
              raise error unless error.class.name.match?(/NotFound/)

              raise Delayed::DeserializationError, "#{error.class.name}, class: #{klass}, primary key: #{id} (#{error.message})"
            end

            def primary_key_value(node, key)
              case node
              when Psych::Nodes::Mapping
                pairs = node.children.each_slice(2).to_a
                pairs.each do |name, value|
                  return value.value if scalar?(name, key) && value.is_a?(Psych::Nodes::Scalar)
                end
                if (named = pairs.find { |name, value| scalar?(name, "name") && scalar?(value, key) })
                  value = pairs.find { |name, _| scalar?(name, "value_before_type_cast") || scalar?(name, "value") }&.last
                  return value.value if value.is_a?(Psych::Nodes::Scalar) && named
                end
                pairs.each do |_, value|
                  found = primary_key_value(value, key)
                  return found unless found.nil?
                end
                nil
              when Psych::Nodes::Sequence
                node.children.each do |child|
                  found = primary_key_value(child, key)
                  return found unless found.nil?
                end
                nil
              end
            end

            def scalar?(node, value)
              node.is_a?(Psych::Nodes::Scalar) && node.value == value
            end
        end
      end

      module ClassMethods
        def enqueue(*args)
          enqueue_job(Delayed::Backend::JobPreparer.new(*args).prepare)
        end

        def enqueue_job(options)
          new(options).tap do |job|
            Base.run_lifecycle(:enqueue, job) do
              job.hook(:enqueue)
              delay_job?(job) ? job.save : job.invoke_job
            end
          end
        end

        def reserve(worker, max_run_time = Base.worker_setting(:max_run_time, DEFAULT_MAX_RUN_TIME))
          find_available(worker.name, worker.read_ahead, max_run_time).detect do |job|
            job.lock_exclusively!(max_run_time, worker.name)
          end
        end

        def recover_from(_error); end

        def before_fork; end

        def after_fork; end

        def work_off(num = 100)
          warn "[DEPRECATION] `Delayed::Job.work_off` is deprecated. Use `Delayed::Worker.new.work_off instead."
          Delayed::Worker.new.work_off(num)
        end

        private
          def delay_job?(job)
            return Delayed::Worker.delay_job?(job) if Delayed::Worker.respond_to?(:delay_job?)

            setting = Base.worker_setting(:delay_jobs, true)
            if setting.is_a?(Proc)
              setting.arity == 1 ? setting.call(job) : setting.call
            else
              setting
            end
          end
      end

      attr_reader :error

      def error=(error)
        @error = error
        self.last_error = "#{error.message}\n#{Array(error.backtrace).join("\n")}" if respond_to?(:last_error=)
      end

      def failed?
        !!failed_at
      end
      alias_method :failed, :failed?

      ParseObjectFromYaml = %r{!ruby/\w+:([^\s]+)}

      def name
        @name ||= payload_object.respond_to?(:display_name) ? payload_object.display_name : payload_object.class.name
      rescue DeserializationError
        ParseObjectFromYaml.match(handler)[1]
      end

      def payload_object=(object)
        @payload_object = object
        self.handler = object.to_yaml
      end

      def payload_object
        @payload_object ||= HandlerLoader.load(handler)
      rescue TypeError, LoadError, NameError, ArgumentError, SyntaxError, Psych::Exception => e
        raise DeserializationError, "Job failed to load: #{e.message}. Handler: #{handler.inspect}"
      end

      def invoke_job
        Base.run_lifecycle(:invoke_job, self) do
          ActiveJob::DeliveryModes.within_attempt do
            hook :before
            payload_object.perform
            hook :success
          end
        rescue Exception => e
          hook :error, e
          raise e
        ensure
          hook :after
        end
      end

      def unlock
        self.locked_at = nil
        self.locked_by = nil
      end

      def hook(name, *args)
        if payload_object.respond_to?(name)
          method = payload_object.method(name)
          method.arity.zero? ? method.call : method.call(self, *args)
        end
      rescue DeserializationError
        nil
      end

      def reschedule_at
        if payload_object.respond_to?(:reschedule_at)
          payload_object.reschedule_at(self.class.db_time_now, attempts)
        else
          self.class.db_time_now + (attempts**4) + 5
        end
      end

      def max_attempts
        payload_object.max_attempts if payload_object.respond_to?(:max_attempts)
      end

      def max_run_time
        return unless payload_object.respond_to?(:max_run_time)
        return unless (run_time = payload_object.max_run_time)

        [ run_time, Base.worker_setting(:max_run_time, DEFAULT_MAX_RUN_TIME) ].min
      end

      def destroy_failed_jobs?
        payload_object.respond_to?(:destroy_failed_jobs?) ? payload_object.destroy_failed_jobs? : Base.worker_setting(:destroy_failed_jobs, true)
      rescue DeserializationError
        Base.worker_setting(:destroy_failed_jobs, true)
      end

      def fail!
        self.failed_at = self.class.db_time_now
        save!
      end

      protected
        def set_default_run_at
          self.run_at ||= self.class.db_time_now
        end

        def reset
          @payload_object = nil
          @name = nil
        end
    end
  end
end
