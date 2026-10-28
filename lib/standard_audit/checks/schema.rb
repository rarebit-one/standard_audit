module StandardAudit
  module Checks
    # A StandardHealth-compatible readiness check that warns when audit_logs
    # is missing an upgrade migration (see StandardAudit::SchemaCheck).
    #
    # Duck-typed like Checks::Retention: `#initialize(name:, critical:)` +
    # `#run`, with no dependency on standard_health. Register it NON-critical:
    #
    #   c.register_check :audit_schema,
    #                    StandardAudit::Checks::Schema,
    #                    critical: false
    #
    # A :warn rolls /health/ready up to :degraded (still HTTP 200), so the gap
    # shows in the readiness JSON without failing the probe.
    class Schema
      def initialize(name: :audit_schema, critical: false)
        @name = name
        @critical = critical
      end

      def run
        gaps = StandardAudit::SchemaCheck.missing
        return { status: :ok } if gaps.empty?

        { status: :warn, missing: gaps, message: StandardAudit::SchemaCheck.message(gaps) }
      end
    end
  end
end
