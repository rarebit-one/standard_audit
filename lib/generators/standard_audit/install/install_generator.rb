require "rails/generators"

module StandardAudit
  module Generators
    # Installs StandardAudit in a host Rails application.
    #
    # Creates the migration for the `audit_logs` table and writes the
    # initializer at `config/initializers/standard_audit.rb`.
    #
    # Idempotent: re-running the generator will skip pieces it has already
    # installed. Pass `--skip-*` flags to opt out of individual steps and
    # `--force` to overwrite an existing initializer.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      desc <<~DESC
        Installs StandardAudit. By default this:
          * copies a CreateAuditLogs migration into db/migrate/
          * writes config/initializers/standard_audit.rb

        Use --skip-* flags to opt out of individual steps when re-running on an
        existing install. The generator is idempotent — already-installed
        pieces are skipped with a clear message. Pass --force to overwrite an
        existing initializer.
      DESC

      class_option :skip_migration, type: :boolean, default: false,
        desc: "Do not copy the CreateAuditLogs migration into db/migrate"
      class_option :skip_initializer, type: :boolean, default: false,
        desc: "Do not write config/initializers/standard_audit.rb"
      class_option :force, type: :boolean, default: false,
        desc: "Overwrite config/initializers/standard_audit.rb if it already exists"

      def self.next_migration_number(dirname)
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      def copy_migration
        if options[:skip_migration]
          say_status("skip", "db/migrate/*_create_audit_logs.rb (--skip-migration)", :yellow)
          return
        end

        if existing_migration
          say_status(
            "identical",
            "AuditLog migration already present (#{relative_migration_path(existing_migration)}), skipping",
            :blue
          )
          return
        end

        migration_template "create_audit_logs.rb.erb", "db/migrate/create_audit_logs.rb"
      end

      def copy_initializer
        initializer_path = "config/initializers/standard_audit.rb"

        if options[:skip_initializer]
          say_status("skip", "#{initializer_path} (--skip-initializer)", :yellow)
          return
        end

        if File.exist?(File.join(destination_root, initializer_path)) && !options[:force]
          say_status("identical", "#{initializer_path} (already exists; pass --force to overwrite)", :blue)
          return
        end

        template "initializer.rb.erb", initializer_path, force: options[:force]
      end

      no_commands do
        def existing_migration
          Dir.glob(File.join(destination_root, "db/migrate/*_create_audit_logs.rb")).first
        end

        def relative_migration_path(absolute_path)
          Pathname.new(absolute_path).relative_path_from(Pathname.new(destination_root)).to_s
        rescue ArgumentError
          absolute_path
        end
      end
    end
  end
end
