# StandardAudit

Database-backed audit logging for Rails via ActiveSupport::Notifications.

StandardAudit is a standalone Rails engine that captures audit events into a dedicated `audit_logs` table. It uses [GlobalID](https://github.com/rails/globalid) for polymorphic references, making it work with any ActiveRecord model without foreign keys or tight coupling.

## Installation

Add to your Gemfile:

```ruby
gem "standard_audit"
```

Run the install generator:

```bash
rails generate standard_audit:install
rails db:migrate
```

This creates:
- A migration for the `audit_logs` table (UUID primary keys, JSON metadata)
- An initializer at `config/initializers/standard_audit.rb`

## Quick Start

### 1. Subscribe to events

```ruby
# config/initializers/standard_audit.rb
StandardAudit.configure do |config|
  config.subscribe_to "myapp.*"
end
```

### 2. Instrument events in your code

```ruby
ActiveSupport::Notifications.instrument("myapp.orders.created", {
  actor: current_user,
  target: @order,
  scope: current_organisation
})
```

### 3. Query the logs

```ruby
StandardAudit::AuditLog.for_actor(current_user).this_week
```

## Recording Events

StandardAudit provides three ways to record audit events.

### Convenience API

The simplest approach — call `StandardAudit.record` directly:

```ruby
StandardAudit.record("orders.created",
  actor: current_user,
  target: @order,
  scope: current_organisation,
  metadata: { total: @order.total }
)
```

When `actor` is omitted, it falls back to the configured `current_actor_resolver` (which reads from `Current.user` by default).

### ActiveSupport::Notifications

Instrument events and let the subscriber handle persistence:

```ruby
ActiveSupport::Notifications.instrument("myapp.orders.created", {
  actor: current_user,
  target: @order,
  scope: current_organisation,
  total: 99.99
})
```

Any payload keys not in the reserved set (`actor`, `target`, `scope`, `request_id`, `ip_address`, `user_agent`, `session_id`) are stored as metadata.

### Block form

Wrap an operation so the event is only recorded if the block succeeds:

```ruby
StandardAudit.record("orders.created", actor: current_user, target: @order) do
  @order.process!
end
```

This uses `ActiveSupport::Notifications.instrument` under the hood.

## Model Concerns

### Auditable

Include `StandardAudit::Auditable` in models that act as actors or targets:

```ruby
class User < ApplicationRecord
  include StandardAudit::Auditable
end
```

This provides:

```ruby
user.audit_logs_as_actor   # logs where this user is the actor
user.audit_logs_as_target  # logs where this user is the target
user.audit_logs            # logs where this user is either
user.record_audit("users.updated", target: @profile)
```

### AuditScope

Include `StandardAudit::AuditScope` in tenant/organisation models:

```ruby
class Organisation < ApplicationRecord
  include StandardAudit::AuditScope
end
```

This provides:

```ruby
organisation.scoped_audit_logs  # all logs scoped to this organisation
```

## Configuration Reference

```ruby
StandardAudit.configure do |config|
  # -- Subscriptions --
  # Subscribe to ActiveSupport::Notifications patterns.
  # Supports wildcards.
  config.subscribe_to "myapp.*"
  config.subscribe_to "auth.*"

  # -- Extractors --
  # How to pull actor/target/scope from notification payloads.
  # Defaults shown below.
  config.actor_extractor  = ->(payload) { payload[:actor] }
  config.target_extractor = ->(payload) { payload[:target] }
  config.scope_extractor  = ->(payload) { payload[:scope] }

  # -- Current Attribute Resolvers --
  # Fallbacks used when payload values are nil.
  # Designed to work with Rails Current attributes.
  config.current_actor_resolver      = -> { Current.user }
  config.current_request_id_resolver = -> { Current.request_id }
  config.current_ip_address_resolver = -> { Current.ip_address }
  config.current_user_agent_resolver = -> { Current.user_agent }
  config.current_session_id_resolver = -> { Current.session_id }

  # -- Sensitive Data --
  # Keys automatically stripped from metadata.
  config.sensitive_keys += %i[my_custom_secret]  # added to built-in defaults

  # -- Metadata Builder --
  # Optional proc to transform metadata before storage.
  config.metadata_builder = ->(metadata) { metadata.slice(:relevant_key) }

  # -- Async Processing --
  # Offload audit log creation to ActiveJob.
  config.async = false
  config.queue_name = :default

  # -- Feature Toggle --
  config.enabled = true

  # -- GDPR --
  # Metadata keys to strip during anonymization.
  config.anonymizable_metadata_keys = %i[email name ip_address]

  # -- Retention --
  config.retention_days = 90
  config.auto_cleanup = false
end
```

### Default Current Attribute Resolvers

Out of the box, StandardAudit reads from `Current` if it responds to the relevant method. This means if your app (or an auth library like StandardId) populates `Current.user`, `Current.request_id`, etc., audit logs automatically capture request context with zero configuration.

## Query Interface

`StandardAudit::AuditLog` ships with composable scopes:

### By association

```ruby
AuditLog.for_actor(user)          # logs for a specific actor
AuditLog.for_target(order)        # logs for a specific target
AuditLog.for_scope(organisation)  # logs within a scope/tenant
AuditLog.by_actor_type("User")    # logs by actor class name
AuditLog.by_target_type("Order")  # logs by target class name
AuditLog.by_scope_type("Organisation")
```

### By event

```ruby
AuditLog.by_event_type("orders.created")   # exact match
AuditLog.matching_event("orders.%")        # SQL LIKE pattern
```

### By time

```ruby
AuditLog.today
AuditLog.yesterday
AuditLog.this_week
AuditLog.this_month
AuditLog.last_n_days(30)
AuditLog.since(1.hour.ago)
AuditLog.before(1.day.ago)
AuditLog.between(start_time, end_time)
```

### By request context

```ruby
AuditLog.for_request("req-abc-123")
AuditLog.from_ip("192.168.1.1")
AuditLog.for_session("session-xyz")
```

### Ordering

```ruby
AuditLog.chronological           # oldest first
AuditLog.reverse_chronological   # newest first
AuditLog.recent(20)              # newest 20 records
```

### Composing queries

All scopes are chainable:

```ruby
AuditLog
  .for_scope(current_organisation)
  .by_event_type("orders.created")
  .this_month
  .reverse_chronological
```

## Multi-Tenancy

StandardAudit supports multi-tenancy through the `scope` column. Pass any ActiveRecord model as the scope — typically an Organisation or Account:

```ruby
StandardAudit.record("orders.created",
  actor: current_user,
  target: @order,
  scope: current_organisation
)
```

Then query all audit activity within that tenant:

```ruby
StandardAudit::AuditLog.for_scope(current_organisation)
```

The scope is stored as a GlobalID string, so it works with any model class.

## Async Processing

For high-throughput applications, offload audit log creation to a background job:

```ruby
StandardAudit.configure do |config|
  config.async = true
  config.queue_name = :audit  # default: :default
end
```

When async is enabled, `StandardAudit::CreateAuditLogJob` serialises actor, target, and scope as GlobalID strings and resolves them back when the job runs. If a referenced record has been deleted between event capture and job execution, the GID string and type are preserved on the audit log (the record just won't be resolvable).

## GDPR Compliance

### Right to Erasure (Anonymization)

Strip personally identifiable information from audit logs while preserving the event timeline:

```ruby
StandardAudit::AuditLog.anonymize_actor!(user)
```

This:
- Replaces `actor_gid` / `target_gid` with `[anonymized]` where the user appears
- Clears `ip_address`, `user_agent`, and `session_id`
- Removes metadata keys listed in `anonymizable_metadata_keys`

### Right to Access (Export)

Export all audit data for a specific user:

```ruby
data = StandardAudit::AuditLog.export_for_actor(user)
File.write("export.json", JSON.pretty_generate(data))
```

Returns a hash with `subject`, `exported_at`, `total_records`, and a `records` array.

## Rake Tasks

```bash
# Delete logs older than N days (default: retention_days config or 90)
rake standard_audit:cleanup[180]

# Archive old logs to a JSON file before deleting
rake standard_audit:archive[90,audit_backup.json]

# Show statistics
rake standard_audit:stats

# GDPR: anonymize all logs for an actor
rake "standard_audit:anonymize_actor[gid://myapp/User/123]"

# GDPR: export all logs for an actor
rake "standard_audit:export_actor[gid://myapp/User/123,export.json]"
```

## Database Support

The migration uses `json` column type by default, which works across:

| Database   | Column Type | Notes |
|------------|-------------|-------|
| PostgreSQL | `jsonb`     | Consider changing `json` to `jsonb` in the migration for better query performance |
| MySQL      | `json`      | Native JSON support |
| SQLite     | `json`      | Stored as text; suitable for development and testing |

For PostgreSQL, edit the generated migration to use `jsonb` instead of `json`:

```ruby
t.jsonb :metadata, default: {}
```

## Best Practices

**What to audit**: Authentication events, data mutations, permission changes, financial transactions, admin actions, data exports, and API access from external services.

**Sensitive data**: Configure `sensitive_keys` to automatically strip passwords, tokens, and secrets from metadata. Add domain-specific keys as needed:

```ruby
config.sensitive_keys += %i[medical_record_number]  # extend the built-in defaults
```

**Performance**: For high-volume applications, enable async processing and ensure your `audit_logs` table has appropriate indexes (the install generator adds them by default). Consider partitioning by `occurred_at` for very large tables.

**Retention**: Set `retention_days` in your configuration and run `rake standard_audit:cleanup` via a scheduled job (e.g., cron or SolidQueue recurring). Archive before deleting if you need long-term storage.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
