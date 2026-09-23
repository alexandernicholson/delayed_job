# frozen_string_literal: true

module Delayed
  module Backend
    module SolidQueue
      class MongoStore
        FIELDS = { id: "_id", queue: "queue_name", priority: "priority", run_at: "scheduled_at", created_at: "created_at",
                   failed_at: "finished_at", locked_at: "claimed_at" }.freeze
        OPERATORS = { eq: "$eq", not_eq: "$ne", in: "$in", not_in: "$nin", lt: "$lt", lte: "$lte", gt: "$gt", gte: "$gte" }.freeze
        RESET = { state: true, process_id: true, claim_token: true, claimed_at: true, started_at: true, timeout_at: true,
                  error: true, finished_at: true, expires_at: true }.freeze

        def fetch(status, conditions, order:, limit:)
          sort = order.to_h { |name, dir| [ FIELDS.fetch(name), dir == :desc ? -1 : 1 ] }
          sort["_id"] ||= 1
          cursor = collection.find(selector(status, conditions), **options).sort(sort)
          cursor = cursor.limit(limit) if limit
          records_for(cursor.to_a)
        end

        def count(status, conditions)
          collection.count_documents(selector(status, conditions), **options)
        end

        def find(id)
          bson_id = object_id(id)
          document = bson_id && collection.find({ _id: bson_id }, **options).limit(1).first
          document && records_for([ document ]).first
        end

        def latest(active_job_id)
          document = collection.find({ active_job_id: active_job_id }, **options).sort(_id: -1).limit(1).first
          document && records_for([ document ]).first
        end

        def delete(status, jobs)
          return 0 if jobs.empty?

          if status == :claimed
            ids = jobs.map(&:bson_id)
            claimed = []
            deleted = ::SolidQueue::Job.transaction(operation: "delayed_job_delete_claimed") do
              claimed = collection.find({ _id: { "$in" => ids }, state: "claimed" }, **options).map { |document| ::SolidQueue::Job.from_document(document) }
              claimed.each { |job| ::SolidQueue::BatchExecution.complete(job) if job.batched? }
              count = collection.delete_many({ _id: { "$in" => claimed.map(&:bson_id) }, state: "claimed" }, **options).deleted_count
              ::SolidQueue::Job.delete_recurring_markers(claimed.map(&:bson_id))
              ::SolidQueue::Deduplication.release(claimed.select(&:deduplicated?), windowed: true)
              count
            end
            claimed.each(&:unblock_next_blocked_job)
            deleted
          else
            result = ::SolidQueue.const_get("#{status.to_s.camelize}Execution").discard_all_from_jobs(jobs)
            result.is_a?(Integer) ? result : jobs.size
          end
        end

        def claim(record, process, claimed_at: nil)
          claimed = ::SolidQueue::ReadyExecution.claiming([ record.job.id ], process.id).any?
          if claimed && claimed_at
            collection.update_one({ _id: record.job.bson_id, state: "claimed", process_id: process.bson_id },
              { "$set" => { claimed_at: claimed_at } }, **options)
          end
          claimed
        end

        def refresh_claim(record, now)
          collection.update_one(
            { _id: record.job.bson_id, state: "claimed", process_id: ::SolidQueue::Mongo.id(record.process_id) },
            { "$set" => { claimed_at: now } }, **options
          ).modified_count == 1
        end

        def steal_claim(record, process, now, cutoff)
          collection.update_one(
            { _id: record.job.bson_id, state: "claimed", process_id: ::SolidQueue::Mongo.id(record.process_id),
              claim_token: record.job.claim_token, claimed_at: { "$lt" => cutoff } },
            { "$set" => { process_id: process.bson_id, claim_token: BSON::ObjectId.new, claimed_at: now },
              "$unset" => { started_at: true, timeout_at: true }, "$inc" => { claim_generation: 1 } }, **options
          ).modified_count == 1
        end

        def dispatch(record)
          record.job.dispatch.present?
        end

        def dispatch_due(limit)
          ::SolidQueue::ScheduledExecution.dispatch_next_batch(limit)
        end

        def rewrite(record, changes)
          bson_id = record.job.bson_id
          keeps_slot = holds_slot?(record) && stays_ready?(changes)
          fields = { queue_name: changes[:queue], priority: changes[:priority], scheduled_at: time(changes[:run_at]),
                     arguments: ActiveSupport::JSON.encode(changes[:job_data]), updated_at: Time.current }
          rewritten = ::SolidQueue::Job.transaction(operation: "delayed_job_update") do
            if keeps_slot
              next collection.update_one(current_filter(record), { "$set" => fields.merge(state: "ready"), "$unset" => RESET.except(:state) },
                **options).matched_count == 1
            end

            result = collection.update_one(current_filter(record), { "$set" => fields, "$unset" => RESET }, **options)
            next false unless result.matched_count == 1

            if changes[:failed_at]
              collection.update_one({ _id: bson_id, state: nil },
                { "$set" => { state: "failed", error: changes[:error], finished_at: time(changes[:failed_at]) } }, **options)
            else
              ::SolidQueue::Job.find(bson_id).prepare_for_execution
            end
            true
          end
          return unless rewritten

          record.job.unblock_next_blocked_job if holds_slot?(record) && !keeps_slot
          find(bson_id)
        end

        def update_claimed(record, changes)
          collection.update_one(
            current_filter(record),
            { "$set" => { queue_name: changes[:queue], priority: changes[:priority], scheduled_at: time(changes[:run_at]),
                          arguments: ActiveSupport::JSON.encode(changes[:job_data]), updated_at: Time.current } }, **options
          ).modified_count == 1
        end

        def paused_queue_names
          ::SolidQueue::Pause.queue_names
        end

        def processes_named(name)
          ::SolidQueue::Mongo.collection(:processes).find({ name: name }, **options).map { |document| ::SolidQueue::Process.from_document(document) }
        end

        def find_process(name)
          ::SolidQueue::Process.find_by(kind: "Worker", name: name)
        end

        private
          def collection
            ::SolidQueue::Mongo.collection(:jobs)
          end

          def options
            ::SolidQueue::Mongo.session_options
          end

          def holds_slot?(record)
            %i[ ready claimed ].include?(record.status)
          end

          def stays_ready?(changes)
            changes[:failed_at].nil? && (changes[:run_at].nil? || changes[:run_at] <= Time.current)
          end

          def current_filter(record)
            filter = { _id: record.job.bson_id, state: record.status.to_s }
            filter[:claim_token] = record.job.claim_token if record.status == :claimed
            filter
          end

          def selector(status, conditions)
            clauses = conditions.map do |condition|
              { FIELDS.fetch(condition.field) => { OPERATORS.fetch(condition.op) => value(condition) } }
            end
            clauses.empty? ? { state: status.to_s } : { state: status.to_s, "$and" => clauses }
          end

          def value(condition)
            if condition.field == :id
              condition.value.is_a?(Array) ? condition.value.filter_map { |id| object_id(id) } : (object_id(condition.value) || BSON::ObjectId.new)
            elsif condition.value.is_a?(Array)
              condition.value.map { |item| time(item) }
            else
              time(condition.value)
            end
          end

          def object_id(value)
            return value if value.is_a?(BSON::ObjectId)

            BSON::ObjectId.from_string(value.to_s) if BSON::ObjectId.legal?(value.to_s)
          end

          def time(value)
            value.is_a?(ActiveSupport::TimeWithZone) || value.is_a?(DateTime) ? value.to_time.utc : value
          end

          def records_for(documents)
            jobs = documents.map { |document| ::SolidQueue::Job.from_document(document) }
            processes = processes_by_id(jobs.select(&:claimed?).filter_map(&:process_id))
            jobs.map do |job|
              record = Record.new(
                job: job, status: job.state&.to_sym, job_data: job.arguments || {},
                failed_at: (job.finished_at if job.failed?), error: (job.error if job.failed?)
              )
              claimed(record, job, processes[job.process_id]) if job.claimed?
              record
            end
          end

          def claimed(record, job, process)
            record.locked_at = job.claimed_at
            record.process_id = job.process_id
            record.process_name = process&.fetch("name", nil)
            record.stealable = process.nil? || process.dig("metadata", "delayed_job").present? ||
              process["last_heartbeat_at"].nil? || process["last_heartbeat_at"] <= ::SolidQueue.process_alive_threshold.ago
          end

          def processes_by_id(ids)
            return {} if ids.empty?

            ::SolidQueue::Mongo.collection(:processes)
              .find({ _id: { "$in" => ids.uniq.map { |id| ::SolidQueue::Mongo.id(id) } } },
                projection: { name: 1, metadata: 1, last_heartbeat_at: 1 }, **options)
              .to_h { |document| [ document["_id"].to_s, document ] }
          end
      end
    end
  end
end
