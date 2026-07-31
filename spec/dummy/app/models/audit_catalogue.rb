# A host's canonical action vocabulary. The gem knows nothing about this
# constant — it is reached only through `config.audit_catalogue`, and only via
# a callable, so Zeitwerk can reload it.
module AuditCatalogue
  # Written by classes under app/operations/.
  OPERATION_ACTIONS = %w[
    order.created
    order.exported
    user.updated
  ].freeze

  # Written elsewhere (a controller concern, a job, a notification-bus name).
  # `audit!` must accept these, but the orphan check must not demand that an
  # operation writes them — which is why `orphans_within:` exists.
  SERVICE_ACTIONS = %w[
    authorization.denied
  ].freeze

  ACTIONS = (OPERATION_ACTIONS + SERVICE_ACTIONS).freeze
end
