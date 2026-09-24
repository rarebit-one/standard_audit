require "rails/generators"
require "generators/standard_audit/migration_number"

module StandardAudit
  module Generators
    # Adds `audit_logs.checksum_version` (0.14.0). New rows are marked with
    # the digest algorithm they were signed with (2, canonical), so
    # `verify_chain` checks them strictly as v2 and can tell them apart from
    # legacy (v1) rows written before the upgrade.
    class AddChecksumVersionGenerator < Rails::Generators::Base
      include StandardAudit::Generators::MigrationNumber
      source_root File.expand_path("templates", __dir__)

      def copy_migration
        migration_template "add_checksum_version_to_audit_logs.rb.erb",
          "db/migrate/add_checksum_version_to_audit_logs.rb"
      end
    end
  end
end
