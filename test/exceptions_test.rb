# frozen_string_literal: true

require "test_helper"

class ExceptionsTest < ActiveSupport::TestCase
  test "WorkerTimeout is a Timeout::Error that names Delayed::Worker.max_run_time" do
    Delayed::Worker.max_run_time = 1.second

    error = assert_raises(Delayed::WorkerTimeout) { Timeout.timeout(0.01, Delayed::WorkerTimeout) { sleep 1 } }

    assert_kind_of Timeout::Error, error
    assert_equal "execution expired (Delayed::Worker.max_run_time is only 1 second)", error.message
  end

  test "WorkerTimeout pluralizes the seconds" do
    Delayed::Worker.max_run_time = 2.minutes

    assert_equal "expired (Delayed::Worker.max_run_time is only 120 seconds)", Delayed::WorkerTimeout.new("expired").message
  end

  test "FatalBackendError is a RuntimeError" do
    assert_operator Delayed::FatalBackendError, :<, RuntimeError
  end

  test "DeserializationError is a StandardError" do
    assert_operator Delayed::DeserializationError, :<, StandardError
  end

  test "InvalidCallback is a RuntimeError" do
    assert_operator Delayed::InvalidCallback, :<, RuntimeError
  end

  test "Compatibility.executable_prefix is bin" do
    assert_equal "bin", Delayed::Compatibility.executable_prefix
  end
end
