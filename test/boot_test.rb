# frozen_string_literal: true

require "test_helper"

class BootTest < ActiveSupport::TestCase
  test "loads delayed_job on the selected Solid Queue backend" do
    assert_equal BACKEND, SolidQueue.backend.to_sym
    assert_equal "4.2.0.sq1", Delayed::VERSION
    assert defined?(Delayed::Job)
  end
end
