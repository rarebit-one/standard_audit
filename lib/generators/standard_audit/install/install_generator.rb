module StandardAudit
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      def copy_migration
        migration_template "create_audit_logs.rb.erb", "db/migrate/create_audit_logs.rb"
      end

      def copy_initializer
        template "initializer.rb.erb", "config/initializers/standard_audit.rb"
      end
    end
  end
end
