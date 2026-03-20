require_relative "lib/standard_audit/version"

Gem::Specification.new do |spec|
  spec.name        = "standard_audit"
  spec.version     = StandardAudit::VERSION
  spec.authors     = ["Jaryl Sim"]
  spec.email       = ["code@jaryl.dev"]
  spec.homepage    = "https://github.com/rarebit-one/standard_audit"
  spec.summary     = "Database-backed audit logging for Rails via ActiveSupport::Notifications."
  spec.description = "StandardAudit is a standalone Rails gem for database-backed audit logging via ActiveSupport::Notifications. Generic, flexible, and works with any Rails application."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rarebit-one/standard_audit"
  spec.metadata["changelog_uri"] = "https://github.com/rarebit-one/standard_audit/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rarebit-one/standard_audit/issues"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activejob", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "globalid", ">= 1.0"
end
