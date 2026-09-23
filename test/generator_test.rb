# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/delayed_job/delayed_job_generator"

class GeneratorTest < Rails::Generators::TestCase
  tests DelayedJobGenerator
  destination File.join(TEST_ROOT, "tmp", "generator")
  setup :prepare_destination

  test "creates an executable bin/delayed_job script" do
    run_generator

    assert_file "bin/delayed_job" do |content|
      assert_match 'require "delayed/command"', content
      assert_match "Delayed::Command.new(ARGV).daemonize", content
    end
    assert File.executable?(File.join(destination_root, "bin", "delayed_job"))
  end

  test "uses Delayed::Compatibility.executable_prefix when available" do
    Delayed::Compatibility.stubs(:executable_prefix).returns("script")
    run_generator

    assert_file "script/delayed_job", /Delayed::Command\.new\(ARGV\)\.daemonize/
    assert File.executable?(File.join(destination_root, "script", "delayed_job"))
  end

  test "capistrano recipes point to the command docs" do
    error = assert_raises(NotImplementedError) { load "delayed/recipes.rb" }
    assert_match "docs/commands.md", error.message
  end
end
