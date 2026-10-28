module StandardAudit
  # Raised by SchemaCheck when `config.schema_check = :raise` and audit_logs
  # is missing an upgrade migration.
  class MissingUpgradeMigration < StandardError; end

  # Detects an audit_logs table that predates the gem's upgrade migrations.
  #
  # Fresh installs get the `previous_checksum` column and the
  # `[created_at, id]` and `checksum` indexes from the install template, but an
  # older install only gets them by running the upgrade generator, and nothing
  # used to notice when a host never did. The gem keeps writing either way
  # (`chain_parent_column?` is simply false), so the cost is silent: no chain
  # parents are recorded, fork-tolerant `verify_chain` is inactive, and
  # `verify_chain` / `backfill_checksums!` page through the table without the
  # index their keyset cursor needs.
  #
  # `verify!` runs on the first audit write in each process (both the
  # single-row and the batch path) and is cached, so it costs one
  # `connection.indexes` read per process. What it does is governed by
  # `config.schema_check`:
  #
  #   :warn  (default) log one warning naming the generator to run
  #   :raise           raise MissingUpgradeMigration on every write
  #   false            skip the check
  #
  # The same result backs the StandardAudit::Checks::Schema readiness check.
  module SchemaCheck
    UPGRADE_COMMAND = "bin/rails generate standard_audit:add_previous_checksum && " \
                      "bin/rails db:migrate && bin/rails standard_audit:relink_checksums".freeze

    class << self
      # The upgrade pieces audit_logs lacks, as human-readable names; empty
      # when the table is current. Cached per process; `reset!` clears it.
      # Returns an empty Array, uncached, when the table cannot be introspected
      # (no connection, no table yet): the write itself reports that failure,
      # and the next call tries again.
      def missing
        return @missing if defined?(@missing)

        gaps = detect_missing
        gaps.nil? ? [] : (@missing = gaps)
      end

      def verify!
        mode = StandardAudit.config.schema_check
        return if mode.nil? || mode == false

        gaps = missing
        return if gaps.empty?

        raise MissingUpgradeMigration, message(gaps) if mode == :raise
        return if @warned

        @warned = true
        log_warning(message(gaps))
      end

      def message(gaps = missing)
        "standard_audit: audit_logs is missing #{gaps.join(", ")} from an upgrade migration. " \
          "Chain parents are not recorded, so fork-tolerant verify_chain is inactive, and " \
          "verify_chain/backfill_checksums! walk the table without their index. " \
          "Run: #{UPGRADE_COMMAND} (on PostgreSQL, add disable_ddl_transaction! and " \
          "algorithm: :concurrently to the generated add_index calls). " \
          "Set config.schema_check = :raise to fail writes instead, or false to silence this."
      end

      def reset!
        remove_instance_variable(:@missing) if defined?(@missing)
        @warned = false
      end

      private

      def detect_missing
        model = StandardAudit::AuditLog
        indexes = model.connection.indexes(model.table_name).map { |index| Array(index.columns).map(&:to_s) }

        gaps = []
        gaps << "the previous_checksum column" unless model.column_names.include?("previous_checksum")
        gaps << "the [created_at, id] index" unless indexes.any? { |cols| cols.first(2) == %w[created_at id] }
        gaps << "the checksum index" unless indexes.any? { |cols| cols.first == "checksum" }
        gaps
      rescue ActiveRecord::ActiveRecordError
        nil
      end

      def log_warning(text)
        logger = defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
        logger ? logger.warn(text) : Kernel.warn(text)
      end
    end
  end
end
