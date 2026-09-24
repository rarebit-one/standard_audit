module StandardAudit
  module Generators
    # Adds `audit_logs.anonymized_at` (0.12.0). With it, rows erased by
    # `AuditLog.anonymize_actor!` are reported by `verify_chain` as `redacted`
    # rather than as `digest_mismatch` failures.
    class AddAnonymizedAtGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      def copy_migration
        migration_template "add_anonymized_at_to_audit_logs.rb.erb",
          "db/migrate/add_anonymized_at_to_audit_logs.rb"
      end
    end
  end
end
