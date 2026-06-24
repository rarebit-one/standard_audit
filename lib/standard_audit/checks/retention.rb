module StandardAudit
  module Checks
    # A StandardHealth-compatible readiness check that warns when audit_logs
    # retention is unbounded on a production deployment.
    #
    # It is intentionally duck-typed (no hard dependency on standard_health):
    # it exposes the `#initialize(name:, critical:)` + `#run` contract the
    # StandardHealth aggregator calls, so it loads even where standard_health
    # is absent.
    #
    # Register it (NON-critical) in config/initializers/standard_health.rb:
    #
    #   c.register_check :audit_retention,
    #                    StandardAudit::Checks::Retention,
    #                    critical: false
    #
    # A :warn result rolls /health/ready up to :degraded, which is still
    # HTTP 200 — it surfaces the advisory in the readiness JSON WITHOUT failing
    # the probe or blocking a deploy. Only a *critical* check failure returns
    # 503, and this check is never critical.
    #
    # "Production" is ENV["APP_ENVIRONMENT"] == "production" when that var is
    # set (so staging — which also runs RAILS_ENV=production — is not flagged);
    # otherwise it falls back to Rails.env.production?.
    class Retention
      def initialize(name: :audit_retention, critical: false)
        @name = name
        @critical = critical
      end

      def run
        unless production?
          return { status: :ok, detail: "retention advisory only runs on production deployments" }
        end

        days = StandardAudit.config.retention_days
        return { status: :ok, retention_days: days } if days

        {
          status: :warn,
          message: "audit_logs retention is unbounded on production. Set " \
                   "STANDARD_AUDIT_RETENTION_DAYS (or config.retention_days) and schedule " \
                   "StandardAudit::CleanupJob, or treat indefinite retention as a deliberate " \
                   "compliance decision."
        }
      end

      private

      def production?
        app_env = ENV["APP_ENVIRONMENT"].to_s
        return app_env == "production" unless app_env.empty?

        defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
      end
    end
  end
end
