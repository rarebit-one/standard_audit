require "rails/generators"
require "generators/standard_audit/migration_number"

module StandardAudit
  module Generators
    class AddPreviousChecksumGenerator < Rails::Generators::Base
      include StandardAudit::Generators::MigrationNumber
      source_root File.expand_path("templates", __dir__)

      def copy_migration
        migration_template "add_previous_checksum_to_audit_logs.rb.erb",
          "db/migrate/add_previous_checksum_to_audit_logs.rb"
      end
    end
  end
end
