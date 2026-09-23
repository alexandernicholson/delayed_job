# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
BACKEND = ENV.fetch("SOLID_QUEUE_BACKEND", "active_record").to_sym

require "bundler/setup"
require "fileutils"
require "tmpdir"
require "logger"
require "rails"
require "active_job/railtie"
require "action_mailer/railtie"
require "active_record/railtie" if BACKEND == :active_record
require "minitest/autorun"
require "mocha/minitest"
require "active_support/test_case"

TEST_ROOT = Dir.mktmpdir("delayed_job-shim-test")
FileUtils.mkdir_p File.join(TEST_ROOT, "db")
Minitest.after_run { FileUtils.remove_entry(TEST_ROOT) if File.exist?(TEST_ROOT) }

if BACKEND == :active_record
  File.write File.join(TEST_ROOT, "config", "database.yml").tap { |path| FileUtils.mkdir_p File.dirname(path) }, <<~YAML
    test:
      primary:
        adapter: sqlite3
        database: #{File.join(TEST_ROOT, "db", "primary.sqlite3")}
        pool: 20
        timeout: 5000
      queue:
        adapter: sqlite3
        database: #{File.join(TEST_ROOT, "db", "queue.sqlite3")}
        pool: 20
        timeout: 5000
        migrations_paths: db/queue_migrate
  YAML
end

require "solid_queue"
require "delayed_job"

module DelayedJobShimTestApplication
  class Application < Rails::Application
    config.root = TEST_ROOT
    config.eager_load = false
    config.logger = ActiveSupport::Logger.new(nil)
    config.active_job.queue_adapter = :solid_queue
    config.action_mailer.delivery_method = :test
    config.solid_queue.backend = BACKEND
    config.solid_queue.logger = ActiveSupport::Logger.new(nil)
    if BACKEND == :mongodb
      config.solid_queue.mongo_url = ENV.fetch("MONGODB_URI")
    else
      config.solid_queue.connects_to = { database: { writing: :queue } }
    end
  end
end

Rails.application.initialize!

if BACKEND == :mongodb
  SolidQueue::Mongo.prepare!
else
  ActiveRecord::Base.establish_connection(:primary)
  ActiveRecord::Schema.verbose = false
  SolidQueue::Record.connection_pool.with_connection do
    ActiveRecord::Schema.define do
      instance_eval File.read(File.join(Gem.loaded_specs["solid_queue"].full_gem_path, "lib/generators/solid_queue/install/templates/db/queue_schema.rb")).sub(/\AActiveRecord::Schema\[[\d.]+\]\.define\(version: \d+\) do\n/, "").sub(/end\s*\z/, "")
    end
  end
  ActiveRecord::Schema.define do
    create_table :stories, force: true do |t|
      t.string :text
      t.boolean :scoped, default: true
    end
  end
end

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |file| require file }

class ActiveSupport::TestCase
  include ShimTestHelper
end
