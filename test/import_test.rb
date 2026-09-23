# frozen_string_literal: true

require "test_helper"

begin
  require "active_record"
  require "sqlite3"
rescue LoadError
  nil
end

class ImportTest < ActiveSupport::TestCase
  include OpsTestHelper

  if defined?(ActiveRecord::Base)
    class LegacyRecord < ActiveRecord::Base
      self.abstract_class = true
    end
  end

  setup do
    skip "needs Active Record and sqlite3 to host the legacy delayed_jobs table" unless defined?(LegacyRecord)

    @database = File.join(TEST_ROOT, "db", "legacy-#{SecureRandom.hex(4)}.sqlite3")
    LegacyRecord.establish_connection(adapter: "sqlite3", database: @database)
    connection.create_table :delayed_jobs, force: true do |t|
      t.integer :priority, default: 0, null: false
      t.integer :attempts, default: 0, null: false
      t.text :handler, null: false
      t.text :last_error
      t.datetime :run_at
      t.datetime :locked_at
      t.datetime :failed_at
      t.string :locked_by
      t.string :queue
      t.timestamps null: true
    end
  end

  teardown do
    LegacyRecord.remove_connection if defined?(LegacyRecord) && @database
  end

  test "moves an Active Job adapter row into Solid Queue keeping its attributes" do
    run_at = 10.minutes.from_now.change(usec: 0)
    data = OpsActiveJob.new("imported").serialize
    id = legacy_row(handler: adapter_handler(data), priority: 4, queue: "legacy", attempts: 2, run_at: run_at)

    result = import

    assert_equal 1, result.imported
    assert_empty result.skipped_ids
    stored = SolidQueue::Admin.jobs(status: :scheduled).sole
    assert_equal "OpsActiveJob", stored.class_name
    assert_equal data["job_id"], stored.active_job_id
    assert_equal "legacy", stored.queue_name
    assert_equal 4, stored.priority
    assert_in_delta run_at, stored.scheduled_at, 1
    assert_equal 2, Delayed::Job.find(stored.id).attempts
    assert_empty rows
    assert_not_includes rows.map { |row| row["id"] }, id
  end

  test "imported Active Job rows run" do
    legacy_row(handler: adapter_handler(OpsActiveJob.new("ran").serialize), run_at: 1.minute.ago)
    import
    ops_perform_ready_jobs
    assert_equal [ [ "ran" ] ], OpsActiveJob.performed
  end

  test "moves custom payload rows through Delayed::JobWrapper.enqueue_payload with a job id derived from the row" do
    Delayed::JobWrapper.expects(:enqueue_payload).with do |payload, options|
      payload.is_a?(SimpleJob) && options[:job_id] == "delayed_job:delayed_jobs:#{@id}" && options[:queue] == "custom" &&
        options[:priority] == 3 && options[:attempts] == 1 && options[:run_at].is_a?(Time)
    end.returns(OpsActiveJob.new.tap { |job| job.provider_job_id = 1 })
    @id = legacy_row(handler: SimpleJob.new.to_yaml, queue: "custom", priority: 3, attempts: 1, run_at: Time.current)

    result = import(permitted_classes: [ SimpleJob ])

    assert_equal 1, result.imported
    assert_empty rows
  end

  test "custom payloads land in Solid Queue" do
    skip_unless_payload_enqueue!
    id = legacy_row(handler: SimpleJob.new.to_yaml, run_at: 1.minute.ago)

    import(permitted_classes: [ SimpleJob ])

    job = Delayed::Job.all.to_a.sole
    assert_equal "delayed_job:delayed_jobs:#{id}", job.active_job_id
    assert_instance_of SimpleJob, job.payload_object
  end

  test "performable method rows are imported" do
    skip_unless_payload_enqueue!
    skip_unless_performable_method!
    legacy_row(handler: "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/class 'SimpleJob'\nmethod_name: :new\nargs: []\n")

    assert_equal 1, import.imported
    assert_equal "SimpleJob.new", Delayed::Job.first.name
  end

  test "skips and reports rows whose handler can not be loaded" do
    bad = legacy_row(handler: "--- !ruby/object:JobThatDoesNotExist {}\n")
    unpermitted = legacy_row(handler: SimpleJob.new.to_yaml)
    good = legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize))

    result = import

    assert_equal 1, result.imported
    assert_equal [ bad, unpermitted ], result.skipped_ids
    assert_equal 2, result.skipped
    assert_match "JobThatDoesNotExist", result.errors[bad]
    assert_match "SimpleJob", result.errors[unpermitted]
    assert_equal [ bad, unpermitted ], rows.map { |row| row["id"] }
    assert_not_includes rows.map { |row| row["id"] }, good
  end

  test "skips rows whose Active Job class no longer exists" do
    data = OpsActiveJob.new.serialize.merge("job_class" => "RemovedJob")
    id = legacy_row(handler: adapter_handler(data))

    result = import

    assert_equal [ id ], result.skipped_ids
    assert_equal 0, ops_unfinished_count
  end

  test "leaves locked and failed rows alone" do
    locked = legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize), locked_by: "old worker", locked_at: Time.current)
    failed = legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize), failed_at: Time.current)

    result = import

    assert_equal 0, result.imported
    assert_equal [ locked, failed ], rows.map { |row| row["id"] }
    assert_equal 0, ops_unfinished_count
  end

  test "is idempotent when a row was enqueued but not deleted" do
    data = OpsActiveJob.new.serialize
    legacy_row(handler: adapter_handler(data))
    OpsActiveJob.deserialize(data).tap { |job| SolidQueue::Job.enqueue(job) }

    result = import

    assert_equal 0, result.imported
    assert_equal 1, result.already_imported
    assert_empty rows
    assert_equal 1, ops_unfinished_count
  end

  test "rows of another table with the same id are not mistaken for imported ones" do
    connection.rename_table :delayed_jobs, :old_jobs
    legacy_row(handler: SimpleJob.new.to_yaml, table: "old_jobs")
    connection.create_table(:delayed_jobs) { |t| t.integer :priority, :attempts; t.text :handler; t.datetime :run_at, :locked_at, :failed_at, :created_at, :updated_at; t.string :locked_by, :queue }
    legacy_row(handler: SimpleJob.new.to_yaml)
    import(permitted_classes: [ SimpleJob ])

    result = import(table_name: "old_jobs", permitted_classes: [ SimpleJob ])

    assert_equal [ 1, 0 ], [ result.imported, result.already_imported ]
    assert_equal 2, ops_unfinished_count
  end

  test "rows a legacy worker locks after they were read are left to it" do
    id = legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize))
    batch = connection.select_all("SELECT * FROM delayed_jobs")
    connection.update("UPDATE delayed_jobs SET locked_by = 'legacy worker', locked_at = '2026-01-01 00:00:00' WHERE id = #{id}")
    connection.stubs(:select_all).returns(batch)

    result = import

    connection.unstub(:select_all)
    assert_equal [ 0, [] ], [ result.imported, result.skipped_ids ]
    assert_equal 0, ops_unfinished_count
    assert_equal [ "legacy worker" ], rows.map { |row| row["locked_by"] }
  end

  test "rows being imported are locked so legacy workers skip them" do
    id = legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize))
    locked_by = nil
    SolidQueue::Job.expects(:enqueue).with do
      locked_by = connection.select_value("SELECT locked_by FROM delayed_jobs WHERE id = #{id}")
    end.returns(true)

    import

    assert_equal "delayed_job import", locked_by
  end

  test "rows left locked by an interrupted import are imported on the next run" do
    legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize), locked_by: "delayed_job import", locked_at: 1.hour.ago)
    assert_equal 1, import.imported
    assert_empty rows
  end

  test "a row that fails to enqueue is unlocked and reported" do
    id = legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize))
    SolidQueue::Job.expects(:enqueue).raises(SolidQueue::Job::EnqueueError, "database is down")

    result = import

    assert_equal [ id ], result.skipped_ids
    assert_match "database is down", result.errors[id]
    assert_equal [ [ id, nil, nil ] ], rows.map { |row| [ row["id"], row["locked_by"], row["locked_at"] ] }
  end

  test "processes rows in batches" do
    5.times { legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize)) }
    events = []
    subscriber = ->(*, payload) { events << payload }

    result = ActiveSupport::Notifications.subscribed(subscriber, "import.delayed_job") { import(batch_size: 2) }

    assert_equal 5, result.imported
    assert_equal 5, ops_unfinished_count
    assert_equal 1, events.size
    assert_equal({ table_name: "delayed_jobs", batch_size: 2, imported: 5, already_imported: 0, skipped: 0, skipped_ids: [], batches: 3 },
      events.first.slice(:table_name, :batch_size, :imported, :already_imported, :skipped, :skipped_ids, :batches))
  end

  test "reads a custom table name" do
    connection.rename_table :delayed_jobs, :old_jobs
    legacy_row(handler: adapter_handler(OpsActiveJob.new.serialize), table: "old_jobs")
    assert_equal 1, import(table_name: "old_jobs").imported
  end

  test "defaults to the Active Record connection" do
    skip "the default connection is the SQL backend's primary database" unless BACKEND == :active_record
    ActiveRecord::Base.connection.create_table(:delayed_jobs, force: true) do |t|
      t.integer :priority, default: 0
      t.integer :attempts, default: 0
      t.text :handler
      t.datetime :run_at, :locked_at, :failed_at
      t.string :locked_by, :queue
    end
    ActiveRecord::Base.connection.insert("INSERT INTO delayed_jobs (handler) VALUES (#{ActiveRecord::Base.connection.quote(adapter_handler(OpsActiveJob.new.serialize))})")

    assert_equal 1, Delayed::Import.run.imported
  ensure
    ActiveRecord::Base.connection.drop_table(:delayed_jobs, if_exists: true) if BACKEND == :active_record
  end

  private
    def connection
      LegacyRecord.connection
    end

    def import(**options)
      Delayed::Import.run(connection: connection, **options)
    end

    def rows(table = "delayed_jobs")
      connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a
    end

    def legacy_row(table: "delayed_jobs", **attributes)
      attributes = { priority: 0, attempts: 0, queue: nil, run_at: Time.current, created_at: Time.current, updated_at: Time.current }.merge(attributes)
      columns = attributes.keys.map { |name| connection.quote_column_name(name) }.join(", ")
      values = attributes.values.map { |value| connection.quote(value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) ? value.utc.strftime("%Y-%m-%d %H:%M:%S.%6N") : value) }.join(", ")
      connection.insert("INSERT INTO #{table} (#{columns}) VALUES (#{values})")
    end

    def adapter_handler(data)
      ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper.new(data).to_yaml
    end
end
