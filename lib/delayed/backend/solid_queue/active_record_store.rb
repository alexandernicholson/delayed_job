# frozen_string_literal: true

module Delayed
  module Backend
    module SolidQueue
      class ActiveRecordStore
        ASSOCIATIONS = { ready: :ready_execution, scheduled: :scheduled_execution, blocked: :blocked_execution,
                         claimed: :claimed_execution, failed: :failed_execution }.freeze
        COLUMNS = { id: :id, queue: :queue_name, priority: :priority, run_at: :scheduled_at, created_at: :created_at }.freeze

        def fetch(status, conditions, order:, limit:)
          scope = scope_for(status, conditions)
          order.each { |name, dir| scope = scope.order(attribute(name, status).public_send(dir)) }
          scope = scope.order(jobs_table[:id].asc) unless order.any? { |name, _| name == :id }
          scope = scope.limit(limit) if limit
          scope.preload(preloads(status)).map { |job| record_for(job, status) }
        end

        def count(status, conditions)
          scope_for(status, conditions).count
        end

        def find(id)
          job = ::SolidQueue::Job.find_by(id: id) if id.to_s.match?(/\A\d+\z/)
          job && record_for(job, status_of(job))
        end

        def latest(active_job_id)
          job = ::SolidQueue::Job.where(active_job_id: active_job_id).order(id: :desc).first
          job && record_for(job, status_of(job))
        end

        def delete(status, jobs)
          return 0 if jobs.empty?

          if status == :claimed
            ids = jobs.map(&:id)
            destroyed = ::SolidQueue::Job.transaction do
              ::SolidQueue::ClaimedExecution.where(job_id: ids).delete_all
              ::SolidQueue::Job.where(id: ids).to_a.each(&:destroy)
            end
            destroyed.each(&:unblock_next_blocked_job)
            destroyed.size
          else
            ids = jobs.map(&:id)
            execution_class(status).discard_all_from_jobs(jobs)
            ids.size - ::SolidQueue::Job.where(id: ids).count
          end
        end

        def claim(record, process, claimed_at: nil)
          job_id = record.job.id
          claimed = ::SolidQueue::ReadyExecution.transaction do
            execution = ::SolidQueue::ReadyExecution.where(job_id: job_id).non_blocking_lock.first
            next false unless execution

            ::SolidQueue::ClaimedExecution.claiming([ job_id ], process.id) do |executions|
              ::SolidQueue::ReadyExecution.where(id: execution.id).delete_all if executions.any?
            end
            true
          end
          ::SolidQueue::ClaimedExecution.where(job_id: job_id, process_id: process.id).update_all(created_at: claimed_at) if claimed && claimed_at
          claimed
        rescue ::ActiveRecord::RecordNotUnique
          false
        end

        def refresh_claim(record, now)
          ::SolidQueue::ClaimedExecution.where(job_id: record.job.id, process_id: record.process_id).update_all(created_at: now) == 1
        end

        def steal_claim(record, process, now, cutoff)
          ::SolidQueue::ClaimedExecution
            .where(job_id: record.job.id, process_id: record.process_id)
            .where(::SolidQueue::ClaimedExecution.arel_table[:created_at].lt(cutoff))
            .update_all(fresh_claim(process_id: process.id, created_at: now)) == 1
        end

        def dispatch(record)
          ::SolidQueue::ScheduledExecution.dispatch_jobs([ record.job.id ]).positive?
        end

        def dispatch_due(limit)
          ::SolidQueue::ScheduledExecution.dispatch_next_batch(limit)
        end

        def rewrite(record, changes)
          releases_slot = holds_slot?(record) && !stays_ready?(changes)
          rewritten = ::SolidQueue::Job.transaction do
            next false unless current?(record)

            job = ::SolidQueue::Job.find(record.job.id)
            job.update!(queue_name: changes[:queue], priority: changes[:priority], scheduled_at: changes[:run_at], arguments: changes[:job_data])
            if holds_slot?(record) && stays_ready?(changes)
              keep_ready(job, record.status)
            else
              execution_classes.each { |klass| klass.where(job_id: job.id).delete_all }
              if changes[:failed_at]
                ::SolidQueue::FailedExecution.create!(job_id: job.id, error: changes[:error], created_at: changes[:failed_at])
              else
                job.prepare_for_execution
              end
            end
            true
          end
          return unless rewritten

          record.job.unblock_next_blocked_job if releases_slot
          find(record.job.id)
        end

        def update_claimed(record, changes)
          ::SolidQueue::Job.transaction do
            next false unless current?(record)

            ::SolidQueue::Job.find(record.job.id).update!(queue_name: changes[:queue], priority: changes[:priority],
              scheduled_at: changes[:run_at], arguments: changes[:job_data])
          end
        end

        def paused_queue_names
          ::SolidQueue::Pause.pluck(:queue_name)
        end

        def processes_named(name)
          ::SolidQueue::Process.where(name: name).to_a
        end

        def find_process(name)
          ::SolidQueue::Process.find_by(kind: "Worker", name: name)
        end

        private
          def holds_slot?(record)
            %i[ ready claimed ].include?(record.status)
          end

          def stays_ready?(changes)
            changes[:failed_at].nil? && (changes[:run_at].nil? || changes[:run_at] <= Time.current)
          end

          def keep_ready(job, status)
            if status == :ready
              ::SolidQueue::ReadyExecution.where(job_id: job.id).update_all(queue_name: job.queue_name, priority: job.priority)
            else
              ::SolidQueue::ClaimedExecution.where(job_id: job.id).delete_all
              job.dispatch_bypassing_concurrency_limits
            end
          end

          def current?(record)
            case record.status
            when :claimed then ::SolidQueue::ClaimedExecution.where(job_id: record.job.id, process_id: record.process_id).lock.exists?
            when *ASSOCIATIONS.keys then execution_class(record.status).where(job_id: record.job.id).lock.exists?
            else false
            end
          end

          def fresh_claim(attributes)
            attributes[:started_at] = nil
            attributes[:timeout_at] = nil if ::SolidQueue::ClaimedExecution.column_names.include?("timeout_at")
            attributes
          end

          def scope_for(status, conditions)
            conditions.reduce(::SolidQueue::Job.joins(ASSOCIATIONS.fetch(status))) do |scope, condition|
              scope.where(predicate(condition, status))
            end
          end

          def predicate(condition, status)
            attribute = attribute(condition.field, status)
            case condition.op
            when :eq then attribute.eq(condition.value)
            when :not_eq then attribute.not_eq(condition.value)
            when :in then attribute.in(condition.value)
            when :not_in then attribute.not_in(condition.value)
            when :lt then attribute.lt(condition.value)
            when :lte then attribute.lteq(condition.value)
            when :gt then attribute.gt(condition.value)
            when :gte then attribute.gteq(condition.value)
            end
          end

          def attribute(name, status)
            case name
            when :failed_at then ::SolidQueue::FailedExecution.arel_table[:created_at]
            when :locked_at then ::SolidQueue::ClaimedExecution.arel_table[:created_at]
            else jobs_table[COLUMNS.fetch(name)]
            end
          end

          def jobs_table
            ::SolidQueue::Job.arel_table
          end

          def preloads(status)
            case status
            when :claimed then { claimed_execution: :process }
            when :failed then :failed_execution
            else []
            end
          end

          def status_of(job)
            job.finished? ? :finished : job.status&.to_sym
          end

          def record_for(job, status)
            record = Record.new(job: job, status: status, job_data: job.arguments || {})
            case status
            when :failed
              execution = job.failed_execution
              record.failed_at = execution&.created_at
              record.error = execution&.error
            when :claimed
              execution = job.claimed_execution
              process = execution&.process
              record.locked_at = execution&.created_at
              record.process_id = execution&.process_id
              record.process_name = process&.name
              record.stealable = process.nil? || process.metadata.to_h.stringify_keys["delayed_job"].present? ||
                process.last_heartbeat_at <= ::SolidQueue.process_alive_threshold.ago
            end
            record
          end

          def execution_class(status)
            ::SolidQueue.const_get("#{status.to_s.camelize}Execution")
          end

          def execution_classes
            ASSOCIATIONS.keys.map { |status| execution_class(status) }
          end
      end
    end
  end
end
