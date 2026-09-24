module StandardAudit
  module Generators
    # DEPRECATED (0.12.0); scheduled for removal. This is the 0.2 -> 0.3
    # upgrade path that added the `checksum` column. Every install since 0.3
    # creates the column via `standard_audit:install`, and no known host still
    # needs it. Run `standard_audit:add_previous_checksum` on hosts that
    # predate 0.8 instead.
    class AddChecksumsGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      DEPRECATION_MESSAGE = "standard_audit:add_checksums is deprecated and will be removed in a " \
                            "future release. It only upgrades pre-0.3 installs; the install " \
                            "generator has created the checksum column since 0.3.".freeze

      def self.next_migration_number(dirname)
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      def warn_deprecated
        say_status :deprecated, DEPRECATION_MESSAGE, :yellow
        warn "[StandardAudit] DEPRECATION: #{DEPRECATION_MESSAGE}"
      end

      def copy_migration
        migration_template "add_checksum_to_audit_logs.rb.erb", "db/migrate/add_checksum_to_audit_logs.rb"
      end
    end
  end
end
