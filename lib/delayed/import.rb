# frozen_string_literal: true

module Delayed
  module Import
    Result = Struct.new(:imported, :already_imported, :skipped_ids, :errors, :batches, keyword_init: true) do
      def initialize(imported: 0, already_imported: 0, skipped_ids: [], errors: {}, batches: 0)
        super
      end

      def skipped
        skipped_ids.size
      end
    end

    ADAPTER_WRAPPER = "ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper"
    LOCK_NAME = "delayed_job import"

    module_function

    def run(batch_size: 500, connection: nil, table_name: "delayed_jobs", permitted_classes: [])
      connection ||= ::ActiveRecord::Base.connection
      result = Result.new
      payload = { table_name: table_name, batch_size: batch_size }

      ActiveSupport::Notifications.instrument("import.delayed_job", payload) do
        last_id = 0
        loop do
          batch = fetch_batch(connection, table_name, last_id, batch_size)
          break if batch.empty?

          result.batches += 1
          batch.each { |row| import_row(connection, table_name, row, result, permitted_classes) }
          last_id = batch.last["id"]
          break if batch.size < batch_size
        end
        payload.merge!(result.to_h.except(:errors), skipped: result.skipped)
      end

      result
    end

    def fetch_batch(connection, table_name, last_id, batch_size)
      table = connection.quote_table_name(table_name)
      connection.select_all(<<~SQL.squish).to_a
        SELECT * FROM #{table}
        WHERE #{connection.quote_column_name("id")} > #{connection.quote(last_id)} AND #{importable(connection)}
        ORDER BY #{connection.quote_column_name("id")} ASC
        LIMIT #{batch_size.to_i}
      SQL
    end
    private_class_method :fetch_batch

    def import_row(connection, table_name, row, result, permitted_classes)
      id = row["id"]
      claimed = false
      payload = Delayed::Backend::Base::HandlerLoader.load(row["handler"], permitted_classes: permitted_classes)
      raise ArgumentError, "handler does not respond to perform" unless payload.respond_to?(:perform)
      return unless (claimed = claim_row(connection, table_name, id))

      imported = !already_imported?(payload, table_name, id)
      enqueue(payload, row, table_name) if imported
      connection.delete("DELETE FROM #{connection.quote_table_name(table_name)} WHERE #{connection.quote_column_name("id")} = #{connection.quote(id)}")
      imported ? result.imported += 1 : result.already_imported += 1
    rescue StandardError, Psych::Exception => error
      release_row(connection, table_name, id) if claimed
      result.skipped_ids << id
      result.errors[id] = "#{error.class}: #{error.message}"
    end
    private_class_method :import_row

    def importable(connection)
      "((locked_by IS NULL AND locked_at IS NULL) OR locked_by = #{connection.quote(LOCK_NAME)}) AND failed_at IS NULL"
    end
    private_class_method :importable

    def claim_row(connection, table_name, id)
      connection.update(<<~SQL.squish) == 1
        UPDATE #{connection.quote_table_name(table_name)}
        SET locked_by = #{connection.quote(LOCK_NAME)}, locked_at = #{connection.quote(Time.now.utc)}
        WHERE #{connection.quote_column_name("id")} = #{connection.quote(id)} AND #{importable(connection)}
      SQL
    end
    private_class_method :claim_row

    def release_row(connection, table_name, id)
      connection.update(<<~SQL.squish)
        UPDATE #{connection.quote_table_name(table_name)} SET locked_by = NULL, locked_at = NULL
        WHERE #{connection.quote_column_name("id")} = #{connection.quote(id)} AND locked_by = #{connection.quote(LOCK_NAME)}
      SQL
    rescue StandardError
      nil
    end
    private_class_method :release_row

    def active_job_id(payload, table_name, id)
      adapter_wrapper?(payload) ? payload.job_data["job_id"].presence : "delayed_job:#{table_name}:#{id}"
    end
    private_class_method :active_job_id

    def already_imported?(payload, table_name, id)
      job_id = active_job_id(payload, table_name, id)
      job_id.present? && SolidQueue::Admin.find_job(job_id).present?
    end
    private_class_method :already_imported?

    def enqueue(payload, row, table_name)
      options = row_options(row)
      active_job = if adapter_wrapper?(payload)
        enqueue_active_job(payload.job_data, options)
      else
        Delayed::JobWrapper.enqueue_payload(payload, options.merge(job_id: active_job_id(payload, table_name, row["id"])))
      end
      raise(active_job.enqueue_error || ArgumentError.new("row #{row["id"]} was not enqueued")) unless active_job&.provider_job_id
    end
    private_class_method :enqueue

    def enqueue_active_job(job_data, options)
      job_class = job_data["job_class"].to_s.safe_constantize
      raise NameError, "uninitialized constant #{job_data["job_class"]}" unless job_class.is_a?(Class) && job_class <= ActiveJob::Base

      ActiveJob::Base.deserialize(job_data.merge("executions" => options[:attempts])).tap do |active_job|
        active_job.queue_name = options[:queue] if options[:queue]
        active_job.priority = options[:priority]
        SolidQueue::Job.enqueue(active_job, scheduled_at: options[:run_at])
      end
    end
    private_class_method :enqueue_active_job

    def row_options(row)
      {
        queue: row["queue"].presence,
        priority: row["priority"].to_i,
        attempts: row["attempts"].to_i,
        run_at: parse_time(row["run_at"]) || Time.current
      }.compact
    end
    private_class_method :row_options

    def parse_time(value)
      case value
      when nil, "" then nil
      when Time, ActiveSupport::TimeWithZone then value
      else ActiveSupport::TimeZone["UTC"].parse(value.to_s)
      end
    end
    private_class_method :parse_time

    def adapter_wrapper?(payload)
      payload.class.name == ADAPTER_WRAPPER && payload.respond_to?(:job_data)
    end
    private_class_method :adapter_wrapper?
  end
end
