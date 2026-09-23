# frozen_string_literal: true

require "rails/generators/base"
require "delayed/compatibility"

class DelayedJobGenerator < Rails::Generators::Base
  source_paths << File.join(File.dirname(__FILE__), "templates")

  def create_executable_file
    template "script", "#{executable_prefix}/delayed_job"
    chmod "#{executable_prefix}/delayed_job", 0o755
  end

  private
    def executable_prefix
      Delayed::Compatibility.respond_to?(:executable_prefix) ? Delayed::Compatibility.executable_prefix : "bin"
    end
end
