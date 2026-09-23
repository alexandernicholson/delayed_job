# frozen_string_literal: true

solid_queue_task = lambda do |name|
  load File.join(Gem.loaded_specs["solid_queue"].full_gem_path, "lib/solid_queue/tasks.rb") unless Rake::Task.task_defined?(name)
  Rake::Task[name]
end

namespace :jobs do
  desc "Clear the delayed_job queue."
  task :clear, [ :queue ] => :environment do |_, args|
    solid_queue_task.call("solid_queue:clear").invoke(*[ args[:queue] ].compact)
  end

  desc "Start a delayed_job worker."
  task work: :environment_options do
    Delayed::Command.new([ "run" ], @worker_options).daemonize
  end

  desc "Start a delayed_job worker and exit when all available jobs are complete."
  task workoff: :environment_options do
    Delayed::Command.new([ "run" ], @worker_options.merge(exit_on_complete: true)).daemonize
  end

  task environment_options: :environment do
    @worker_options = {
      min_priority: ENV.fetch("MIN_PRIORITY", nil),
      max_priority: ENV.fetch("MAX_PRIORITY", nil),
      queues: (ENV["QUEUES"] || ENV["QUEUE"] || "").split(","),
      quiet: ENV.fetch("QUIET", nil)
    }

    @worker_options[:sleep_delay] = ENV["SLEEP_DELAY"].to_i if ENV["SLEEP_DELAY"]
    @worker_options[:read_ahead] = ENV["READ_AHEAD"].to_i if ENV["READ_AHEAD"]
  end

  desc "Exit with error status if any jobs older than max_age seconds haven't been attempted yet."
  task :check, [ :max_age ] => :environment do |_, args|
    args.with_defaults(max_age: 300)

    solid_queue_task.call("solid_queue:check_latency").invoke(args[:max_age])
  end

  desc "Move unlocked, unfailed rows from the legacy delayed_jobs table into Solid Queue (BATCH_SIZE, TABLE)."
  task import: :environment do
    result = Delayed::Import.run(batch_size: ENV.fetch("BATCH_SIZE", 500).to_i, table_name: ENV.fetch("TABLE", "delayed_jobs"))

    puts "Imported #{result.imported} delayed_jobs rows into Solid Queue (#{result.already_imported} already imported)"
    if result.skipped_ids.any?
      puts "Skipped #{result.skipped_ids.size} rows: #{result.skipped_ids.join(", ")}"
      result.errors.each { |id, message| puts "  #{id}: #{message}" }
    end
  end
end
