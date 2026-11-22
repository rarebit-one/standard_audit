# Offers the gem's readiness checks and env vars to standard_health without
# depending on it. The block runs only when standard_health is loaded (it
# fires `run_load_hooks(:standard_health, ...)`), whichever gem loads first;
# without standard_health it never runs. An app that calls
# `register_default_checks` then gets both checks, non-critical, and can opt
# out or override them by name (`audit_schema: false`).
#
# The names match each check's default `name:`. `audit_retention` is also the
# key of standard_health's own (deprecated) built-in entry, which this
# contribution takes over, so the check registers once either way.
ActiveSupport.on_load(:standard_health) do |health|
  health.contribute_check :audit_retention, "StandardAudit::Checks::Retention", critical: false
  health.contribute_check :audit_schema, "StandardAudit::Checks::Schema", critical: false

  health.contribute_env_vars "standard_audit" do
    recommended :STANDARD_AUDIT_RETENTION_DAYS,
      description: "Days to keep audit_logs rows before StandardAudit::CleanupJob deletes them: a positive " \
                   "integer, or `indefinite` to keep them forever as a deliberate decision. Unset keeps them " \
                   "forever undecided, which the audit_retention check warns about on production. " \
                   "`config.retention_days` in the initializer overrides it.",
      consumed_by: "StandardAudit::Configuration.retention_days_from_env"
  end
end
