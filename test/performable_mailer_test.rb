# frozen_string_literal: true

require "test_helper"

class PerformableMailerTest < ActiveSupport::TestCase
  class MyMailer < ActionMailer::Base
    def signup(email)
      mail to: email, subject: "Delaying Emails #{params&.fetch(:foo, nil)}".strip, from: "delayedjob@example.com", body: "Delaying Emails Body"
    end
  end

  setup do
    ActionMailer::Base.deliveries.clear
  end

  test "ActionMailer classes are extended with DelayMail" do
    assert_kind_of Delayed::DelayMail, MyMailer
  end

  test "delay enqueues a PerformableMailer job" do
    assert_difference -> { queued_jobs.size }, 1 do
      job = MyMailer.delay.signup("john@example.com")

      assert_equal Delayed::PerformableMailer, job.payload_object.class
      assert_equal :signup, job.payload_object.method_name
      assert_equal [ "john@example.com" ], job.payload_object.args
    end
  end

  test "delay passes job options" do
    job = MyMailer.delay(priority: 3, queue: "mailers").signup("john@example.com")

    assert_equal 3, job.priority
    assert_equal "mailers", job.queue
  end

  test "delayed mail is delivered when the job runs" do
    MyMailer.delay.signup("john@example.com")

    assert_empty ActionMailer::Base.deliveries
    perform_ready_jobs
    assert_equal [ [ "john@example.com" ] ], ActionMailer::Base.deliveries.map(&:to)
  end

  test "delay on a mail object raises" do
    error = assert_raises(RuntimeError) { MyMailer.signup("john@example.com").delay }

    assert_equal "Use MyMailer.delay.mailer_action(args) to delay sending of emails.", error.message
  end

  test "delay on a Mail::Message raises" do
    assert_raises(RuntimeError) { Mail::Message.new.delay }
  end

  test "perform calls the method and #deliver on the mailer" do
    email = mock("email")
    mailer_class = mock("MailerClass")
    mailer_class.expects(:signup).with("john@example.com").returns(email)
    email.expects(:deliver).returns(true)

    assert Delayed::PerformableMailer.new(mailer_class, :signup, [ "john@example.com" ]).perform
  end

  test "perform prefers #deliver_now" do
    email = mock("email")
    email.expects(:deliver_now).returns(:delivered)
    email.expects(:deliver).never

    assert_equal :delivered, Delayed::PerformableMailer.new(stub(signup: email), :signup, [ "john@example.com" ]).perform
  end

  test "parameterized mailers enqueue a PerformableMailer job" do
    assert_difference -> { queued_jobs.size }, 1 do
      job = MyMailer.with(foo: 1, bar: 2).delay.signup("john@example.com")

      assert_equal Delayed::PerformableMailer, job.payload_object.class
      assert_equal ActionMailer::Parameterized::Mailer, job.payload_object.object.class
      assert_equal MyMailer, job.payload_object.object.instance_variable_get(:@mailer)
      assert_equal({ foo: 1, bar: 2 }, job.payload_object.object.instance_variable_get(:@params))
      assert_equal :signup, job.payload_object.method_name
      assert_equal [ "john@example.com" ], job.payload_object.args
    end
  end

  test "parameterized mail is delivered with its params when the job runs" do
    MyMailer.with(foo: 1).delay.signup("john@example.com")

    perform_ready_jobs
    assert_equal [ "Delaying Emails 1" ], ActionMailer::Base.deliveries.map(&:subject)
  end

  test "delay on a parameterized mail object raises" do
    assert_raises(RuntimeError) { MyMailer.with(foo: 1, bar: 2).signup("john@example.com").delay }
  end
end
