module StandardAudit
  module Generators
    class AddChecksumsGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      def copy_migration
        migration_template "add_checksum_to_audit_logs.rb.erb", "db/migrate/add_checksum_to_audit_logs.rb"
      end
    end
  end
end
