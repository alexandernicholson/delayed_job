# frozen_string_literal: true

require "test_helper"

class BootTest < ActiveSupport::TestCase
  test "loads delayed_job on the selected Solid Queue backend" do
    assert_equal BACKEND, SolidQueue.backend.to_sym
    assert_equal "4.2.0.sq1", Delayed::VERSION
    assert defined?(Delayed::Job)
  end

  test "creates the Solid Queue schema on the queue database" do
    skip "the MongoDB backend prepares collections instead" unless BACKEND == :active_record

    assert SolidQueue::Record.connection_pool.with_connection { |connection| connection.table_exists?(:solid_queue_jobs) }
    assert_not ActiveRecord::Base.connection_pool.with_connection { |connection| connection.table_exists?(:solid_queue_jobs) }
  end
end
