# frozen_string_literal: true

require "socket"
require "solid_queue"
require "delayed/backend/base"
require_relative "../../active_job/queue_adapters/delayed_job_adapter"
require_relative "solid_queue/condition"
require_relative "solid_queue/relation"
require_relative "solid_queue/active_record_store"
require_relative "solid_queue/mongo_store"

module Delayed
  module Backend
    module SolidQueue
      RecordNotFound = Class.new(defined?(::ActiveRecord::RecordNotFound) ? ::ActiveRecord::RecordNotFound : ::SolidQueue::RecordNotFound)

      StaleJobError = Class.new(StandardError)

      Record = Struct.new(:job, :status, :job_data, :failed_at, :error, :locked_at, :process_id, :process_name, :stealable, keyword_init: true)

      class Job
        include Delayed::Backend::Base

        ATTRIBUTES = %i[ id priority attempts handler queue run_at locked_at locked_by failed_at last_error created_at updated_at ].freeze
        ADAPTER_WRAPPER = "ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper"
        PROCESS_METADATA = { "delayed_job" => true }.freeze

        attr_accessor :id, :priority, :attempts, :queue, :run_at, :locked_at, :locked_by, :failed_at, :last_error,
          :created_at, :updated_at, :active_job_id
        attr_writer :handler
        attr_reader :status

        class << self
          delegate :where, :order, :reorder, :limit, :offset, :first, :last, :to_a, :pluck, :ids, :find_by, :find_by!,
            :find_each, :find_in_batches, :exists?, :delete_all, :destroy_all, :update_all, :count, to: :all

          def all
            Relation.new(self)
          end

          def each(&block)
            all.each(&block)
          end

          def find(id)
            record = store.find(id)
            record = store.latest(record.job.active_job_id) if record && record.status == :finished && record.job.active_job_id
            raise RecordNotFound, "Couldn't find Delayed::Job with 'id'=#{id}" unless visible?(record)

            from_record(record)
          end

          def create(attributes = {})
            new(attributes).tap(&:save)
          end

          def create!(attributes = {})
            new(attributes).tap(&:save!)
          end

          def db_time_now
            Time.current
          end

          def ready_to_run(worker_name, max_run_time)
            all.reservable(worker_name, max_run_time)
          end

          def find_available(worker_name, limit = 5, max_run_time = Base.worker_setting(:max_run_time, Base::DEFAULT_MAX_RUN_TIME))
            store.dispatch_due(limit)
            reservation_process(worker_name, heartbeat: true)
            scope = ready_to_run(worker_name, max_run_time)
            min_priority = Base.worker_setting(:min_priority)
            max_priority = Base.worker_setting(:max_priority)
            queues = Array(Base.worker_setting(:queues, []))
            paused = store.paused_queue_names
            scope = scope.where(priority: min_priority.to_i..) if min_priority
            scope = scope.where(priority: ..max_priority.to_i) if max_priority
            scope = scope.where(queue: queues) if queues.any?
            scope = scope.where.not(queue: paused) if paused.any?
            scope.order(:priority, :run_at).limit(limit).to_a
          end

          def clear_locks!(worker_name)
            store.processes_named(worker_name).each do |process|
              stop_heartbeat(process.id)
              ::SolidQueue::ClaimedExecution.release_for_process(process.id)
              process.deregister if process.metadata.to_h.stringify_keys["delayed_job"]
            end
          end

          def before_fork
            return if ::SolidQueue.mongodb? || !defined?(::ActiveRecord::Base)

            ::ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
          end

          def after_fork
            ::SolidQueue.after_fork!
          end

          def store
            ::SolidQueue.mongodb? ? MongoStore.new : ActiveRecordStore.new
          end

          def from_record(record)
            allocate.tap { |job| job.send(:assign_record, record) }
          end

          def reservation_process(worker_name, heartbeat: false)
            process = store.find_process(worker_name)
            if process
              process.heartbeat if heartbeat
            else
              process = ::SolidQueue::Process.register(kind: "Worker", name: worker_name, pid: ::Process.pid,
                hostname: Socket.gethostname.force_encoding(Encoding::UTF_8), metadata: PROCESS_METADATA)
            end
            start_heartbeat(process) if process.metadata.to_h.stringify_keys["delayed_job"]
            process
          rescue ::SolidQueue::PersistenceError, *record_not_unique
            store.find_process(worker_name) || raise
          end

          private
            def heartbeats
              heartbeat_lock.synchronize do
                if @heartbeats_pid != ::Process.pid
                  @heartbeats = {}
                  @heartbeats_pid = ::Process.pid
                end
                @heartbeats
              end
            end

            def heartbeat_lock
              @heartbeat_lock ||= Mutex.new
            end

            def start_heartbeat(process)
              registry = heartbeats
              heartbeat_lock.synchronize do
                return if registry[process.id.to_s]&.alive?

                registry[process.id.to_s] = Thread.new(process) { |owned| heartbeat_loop(owned) }
              end
            end

            def stop_heartbeat(process_id)
              registry = heartbeats
              heartbeat_lock.synchronize { registry.delete(process_id.to_s) }&.kill
            end

            def heartbeat_loop(process)
              loop do
                sleep ::SolidQueue.process_heartbeat_interval
                begin
                  wrap_in_app_executor { process.heartbeat }
                rescue ::SolidQueue::RecordNotFound
                  break
                rescue StandardError => error
                  ::SolidQueue.on_thread_error&.call(error)
                end
              end
            ensure
              registry = heartbeats
              heartbeat_lock.synchronize { registry.delete(process.id.to_s) if registry[process.id.to_s] == Thread.current }
            end

            def wrap_in_app_executor(&block)
              ::SolidQueue.app_executor ? ::SolidQueue.app_executor.wrap(source: "application.delayed_job", &block) : block.call
            end

            def visible?(record)
              record && record.status && record.status != :finished
            end

            def record_not_unique
              defined?(::ActiveRecord::RecordNotUnique) ? [ ::ActiveRecord::RecordNotUnique ] : []
            end
        end

        def initialize(attributes = {})
          self.attempts = 0
          self.priority = 0
          attributes.each { |name, value| public_send(:"#{name}=", value) }
        end

        def persisted?
          !@record.nil? && !@destroyed
        end

        def new_record?
          !persisted?
        end

        def destroyed?
          !!@destroyed
        end

        def handler
          @handler ||= persisted? ? persisted_handler : @payload_object&.to_yaml
        end

        def payload_object=(object)
          @payload_object = object
          @handler = nil
        end

        def payload_object
          return super unless persisted?

          @payload_object ||= persisted_payload
        end

        def delivery_mode=(mode)
          @delivery_mode = mode.nil? ? nil : Delayed::RetryPolicy.delivery_mode!(mode)
        end

        def delivery_mode
          return Delayed::RetryPolicy.resolve_delivery_mode(@delivery_mode) { payload_object } unless persisted?

          deserialized_active_job.try(:delivery_mode) if active_job_class
        end

        def save
          persisted? ? update_persisted : insert
        end

        def save!
          save || raise(StaleJobError, "Delayed::Job #{id} changed in Solid Queue since it was loaded; reload it and try again")
        end

        def update(attributes)
          attributes.each { |name, value| public_send(:"#{name}=", value) }
          save
        end

        def update!(attributes)
          attributes.each { |name, value| public_send(:"#{name}=", value) }
          save!
        end

        def destroy
          if persisted?
            current = store.find(id)
            store.delete(current.status, [ current.job ]) if self.class.send(:visible?, current)
          end
          @destroyed = true
          self
        end

        def delete
          destroy
        end

        def reload
          record = (store.latest(active_job_id) if active_job_id) || (store.find(id) if id)
          raise RecordNotFound, "Couldn't find Delayed::Job with 'id'=#{id}" unless self.class.send(:visible?, record)

          assign_record(record)
          self
        end

        def lock_exclusively!(max_run_time, worker)
          now = self.class.db_time_now
          process = self.class.reservation_process(worker)
          locked = case status
          when :ready then store.claim(record, process)
          when :scheduled then run_at <= now && store.dispatch(record) && store.claim(record, process)
          when :claimed
            if locked_by == worker
              store.refresh_claim(record, now)
            elsif stealable? && (locked_at.nil? || locked_at < now - max_run_time)
              store.steal_claim(record, process, now, now - max_run_time)
            end
          end
          return false unless locked

          assign_record(store.find(id))
          self.locked_at = now
          self.locked_by = worker
          true
        end

        def attributes
          ATTRIBUTES.index_with { |name| public_send(name) }.stringify_keys
        end

        def ==(other)
          other.is_a?(Job) && !id.nil? && other.id.to_s == id.to_s
        end
        alias_method :eql?, :==

        def hash
          [ Job, id.to_s ].hash
        end

        def inspect
          "#<#{self.class.name} id: #{id.inspect}, queue: #{queue.inspect}, priority: #{priority.inspect}, " \
            "attempts: #{attempts.inspect}, run_at: #{run_at.inspect}, locked_by: #{locked_by.inspect}, failed_at: #{failed_at.inspect}>"
        end

        private
          attr_reader :record

          def store
            self.class.store
          end

          def stealable?
            !!record&.stealable
          end

          def assign_record(record)
            @record = record
            @status = record.status
            @destroyed = false
            job = record.job
            data = record.job_data
            executions = data["executions"].to_i
            self.id = job.id
            self.active_job_id = job.active_job_id
            self.priority = job.priority
            self.queue = job.queue_name
            self.run_at = job.scheduled_at || job.created_at
            self.created_at = job.created_at
            self.updated_at = (job.updated_at if job.respond_to?(:updated_at)) || job.created_at
            self.attempts = status == :failed ? executions + 1 : executions
            self.failed_at = record.failed_at
            self.last_error = status == :failed ? format_error(record.error) : data["last_error"]
            self.locked_at = record.locked_at
            self.locked_by = record.process_name || (record.process_id && "process:#{record.process_id}")
            @handler = nil
            reset
          end

          def format_error(error)
            error = (error || {}).to_h.stringify_keys
            message = error["message"].to_s
            backtrace = Array(error["backtrace"])
            message.empty? && backtrace.empty? ? nil : "#{message}\n#{backtrace.join("\n")}"
          end

          def insert
            set_default_run_at
            lock = [ locked_by, locked_at ] if locked_by
            failure = { failed_at: failed_at, last_error: last_error, attempts: attempts } if failed_at
            payload = payload_object
            active_job = enqueue_active_job(payload)
            self.active_job_id = active_job.job_id
            return false unless active_job.provider_job_id

            assign_record(store.find(active_job.provider_job_id))
            @payload_object = payload
            if failure
              assign_attributes(failure)
              update_persisted
            elsif lock
              claim_for(*lock)
            end
            true
          end

          def enqueue_active_job(payload)
            if adapter_wrapper?(payload)
              enqueue_adapter_wrapper(payload)
            elsif Delayed::JobWrapper.respond_to?(:enqueue_payload)
              Delayed::JobWrapper.enqueue_payload(payload, { queue: queue, priority: priority, run_at: run_at,
                attempts: attempts, job_id: active_job_id, delivery_mode: @delivery_mode }.compact)
            else
              raise NotImplementedError, "Delayed::JobWrapper.enqueue_payload is required to save Delayed::Job records"
            end
          end

          def adapter_wrapper?(payload)
            payload.class.name == ADAPTER_WRAPPER && payload.respond_to?(:job_data)
          end

          def enqueue_adapter_wrapper(payload)
            ActiveJob::Base.deserialize(payload.job_data.deep_dup).tap do |active_job|
              active_job.queue_name = queue if queue
              active_job.priority = priority if priority
              ::SolidQueue::Job.enqueue(active_job, scheduled_at: run_at || Time.current)
            end
          end

          def claim_for(worker, claimed_at)
            process = self.class.reservation_process(worker)
            store.claim(record, process, claimed_at: claimed_at || self.class.db_time_now)
            assign_record(store.find(id))
          end

          def assign_attributes(attributes)
            attributes.each { |name, value| public_send(:"#{name}=", value) }
          end

          def update_persisted
            lock = [ locked_by, locked_at ] if locked_by && !failed_at
            payload = @payload_object
            if status == :claimed && lock && locked_by == record.process_name
              return false unless store.update_claimed(record, store_changes)

              assign_record(store.find(id))
            else
              rewritten = store.rewrite(record, store_changes)
              return false unless rewritten

              assign_record(rewritten)
              claim_for(*lock) if lock && status == :ready
            end
            @payload_object = payload
            true
          end

          def store_changes
            data = record.job_data.deep_dup
            executions = failed_at ? [ attempts.to_i - 1, 0 ].max : attempts.to_i
            data.merge!("executions" => executions, "queue_name" => queue, "priority" => priority,
              "scheduled_at" => run_at&.utc&.iso8601(9))
            last_error && !failed_at ? data["last_error"] = last_error : data.delete("last_error")
            { queue: queue, priority: priority, run_at: run_at || self.class.db_time_now, job_data: data,
              failed_at: failed_at, error: (error_document if failed_at) }
          end

          def error_document
            lines = last_error.to_s.split("\n")
            { "exception_class" => error&.class&.name || "RuntimeError", "message" => lines.first.to_s, "backtrace" => lines.drop(1) }
          end

          def persisted_payload
            return adapter_wrapper unless active_job_class

            active_job = deserialized_active_job
            return active_job.payload_object if active_job.respond_to?(:payload_object)

            argument = wrapped_argument(active_job)
            if argument.respond_to?(:perform)
              argument
            elsif argument.is_a?(String)
              HandlerLoader.load(argument)
            else
              adapter_wrapper
            end
          rescue Delayed::DeserializationError
            raise
          rescue ActiveJob::DeserializationError, NameError, ArgumentError, TypeError, LoadError, Psych::Exception => e
            raise Delayed::DeserializationError, "Job failed to load: #{e.message}. Handler: #{handler.inspect}"
          end

          def persisted_handler
            return adapter_wrapper.to_yaml unless active_job_class
            return deserialized_active_job.handler if active_job_class.method_defined?(:handler)

            argument = raw_wrapped_argument
            argument.is_a?(String) && argument.start_with?("---") ? argument : payload_object.to_yaml
          rescue StandardError
            fallback_handler
          end

          def active_job_class
            klass = record.job_data["job_class"].to_s.safe_constantize
            klass if klass.is_a?(Class) && klass <= ActiveJob::Base
          end

          def deserialized_active_job
            ActiveJob::Base.deserialize(record.job_data.deep_dup)
          end

          def adapter_wrapper
            ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper.new(record.job_data.deep_dup)
          end

          def wrapped_argument(active_job)
            return unless active_job.class.name == "Delayed::JobWrapper"

            active_job.send(:deserialize_arguments_if_needed)
            active_job.arguments.first
          end

          def raw_wrapped_argument
            Array(record.job_data["arguments"]).first if record.job_data["job_class"] == "Delayed::JobWrapper"
          end

          def fallback_handler
            argument = raw_wrapped_argument
            return argument if argument.is_a?(String) && argument.start_with?("---")

            name = argument["_aj_serialized"].to_s.delete_suffix("Serializer").presence if argument.is_a?(Hash)
            "--- !ruby/object:#{name || record.job_data["job_class"]} {}\n"
          end
      end
    end
  end

  Job = Backend::SolidQueue::Job unless const_defined?(:Job, false)
end
