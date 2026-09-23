Gem::Specification.new do |spec|
  spec.name = "delayed_job"
  spec.version = "4.2.0.sq1"
  spec.summary = "delayed_job's API, running on Solid Queue"
  spec.description = "A drop-in replacement for delayed_job 4.2 that stores and runs jobs with Solid Queue on SQL or MongoDB."
  spec.authors = [ "Alexander Nicholson" ]
  spec.homepage = "https://github.com/alexandernicholson/delayed_job"
  spec.licenses = [ "MIT" ]
  spec.required_ruby_version = ">= 3.2"
  spec.require_paths = [ "lib" ]
  spec.files = Dir["lib/**/*", "docs/**/*", "LICENSE.md", "README.md"]
  spec.metadata = { "rubygems_mfa_required" => "true", "source_code_uri" => spec.homepage }

  spec.add_dependency "activesupport", ">= 7.1", "< 9.0"
  spec.add_dependency "activejob", ">= 7.1", "< 9.0"
  spec.add_dependency "solid_queue", ">= 1.7"
end
