# frozen_string_literal: true

if BACKEND == :active_record && !SolidQueue::Record.connection_pool.with_connection { |connection| connection.table_exists?(:solid_queue_jobs) }
  schema = File.read(File.join(Gem.loaded_specs["solid_queue"].full_gem_path, "lib/generators/solid_queue/install/templates/db/queue_schema.rb"))
  body = schema.sub(/\AActiveRecord::Schema\[[\d.]+\]\.define\(version: \d+\) do\n/, "").sub(/end\s*\z/, "")
  SolidQueue::Record.connection_pool.with_connection { |connection| connection.instance_eval(body) }
  SolidQueue::Record.reset_column_information
  SolidQueue::Record.descendants.each(&:reset_column_information)
end
