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

The generator is idempotent — re-running it skips the migration when a `*_create_audit_logs.rb` already exists in `db/migrate/`, and skips the initializer when `config/initializers/standard_audit.rb` already exists. Pass `--skip-migration` or `--skip-initializer` to opt out of individual steps, or `--force` to overwrite the existing initializer.

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

StandardAudit provides four ways to record audit events. On Rails 8.1+, prefer `Rails.event` — it is the standard Rails interface for structured events.

### Rails.event (Rails 8.1+)

StandardAudit registers a `Rails.event` subscriber at boot, so any `notify` call whose name matches a configured `subscribe_to` pattern is persisted automatically:

```ruby
class ApplicationController < ActionController::Base
  before_action do
    Rails.event.set_context(
      request_id: request.request_id,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end
end

Rails.event.tagged("checkout") do
  Rails.event.notify("myapp.orders.created",
    actor: current_user,
    target: @order,
    scope: current_organisation,
    total: @order.total
  )
end
```

`Rails.event.set_context` values override the `Current.*` resolvers for `request_id`, `ip_address`, `user_agent`, and `session_id`. Tags and `source_location` are captured as metadata under the reserved keys `_tags` and `_source`.

### Convenience API

Call `StandardAudit.record` directly:

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

For Rails < 8.1, or when `Rails.event` is unavailable, instrument events via `ActiveSupport::Notifications`:

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

## Operation Audit Contract

`StandardAudit::Operation` makes an operation *declare* what it audits, so a new
mutating operation cannot silently ship with no audit trail. It is a **module,
not a base class** — it contributes the audit contract and nothing else (no
`call`, no `Result`, no `execute`), so it drops into any operation style.

```ruby
class ApplicationOperation
  include StandardAudit::Operation   # ← the whole adoption, for a shared base
end

class Orders::CreateOperation < ApplicationOperation
  audits "order.created"

  def execute
    order = Order.create!(**attrs)
    audit!("order.created", target: order, metadata: { total: order.total })
  end
end

class Orders::ReindexOperation < ApplicationOperation
  audit_none!   # projection of already-audited state
end
```

- `audits "x.y"` — the action(s) this operation may write. Repeatable args; the
  declaration is **not inherited**, so every leaf states its own intent.
- `audit_none!` — mutates state but deliberately records nothing. Leave the
  reason as a comment.
- `audit_abstract!` — a base or intermediate class, not a real operation.
- `audit!(action, **attrs)` — private; the single write path. Args forward
  straight to `StandardAudit.record`. Call it inside the operation's own
  transaction so the row commits with the state change.

### Adoption shapes

Both work with no configuration:

1. **A shared base includes the module once**, and the real operations are its
   subclasses (registered via `inherited`). The base declares nothing and has
   subclasses, so it is excluded from the checks automatically. A class that
   *did* declare is never excluded this way, so subclassing a real operation
   cannot quietly drop it.
2. **Every operation includes the module directly**, with no shared base
   (registered via `included`).

Both land in one registry, so a single meta-spec covers a codebase mixing them.

### The catalogue

The gem has no knowledge of your action vocabulary. Declare it as a **callable** —
referencing an autoloadable constant eagerly from an initializer pins the
first-loaded copy and breaks Zeitwerk reloading:

```ruby
StandardAudit.configure(baseline: true) do |config|
  config.audit_catalogue = -> { AuditCatalogue::ACTIONS }
end
```

`nil` (the default) skips the membership check entirely, so the DSL is adoptable
before you have a catalogue. **Membership is the only rule** — there is no
dot-count, case, prefix, or namespace validation, because an action may
legitimately carry a notification-bus namespace verbatim.

### Error policy

`StandardAudit::Operation::DeclarationError` — a declaration↔write mismatch —
**always propagates**, ahead of any generic rescue. It is raised in local
environments only (`config.verify_audit_declarations`); in production `audit!`
just writes, because a developer's mistake must not 500 a user. The meta-spec is
the real gate.

A genuine **write** failure is governed by config:

```ruby
config.raise_on_audit_write_error = true   # default false: report and swallow
config.audit_write_error_handler  = ->(error, action:, operation:) { ... }
```

Default `false` matches most apps, but set it `true` where an unaudited state
change is itself a compliance failure — the audit write then aborts the
operation.

### The meta-spec

The analysis is **plain Ruby**, so you can assert on it however you like:

```ruby
StandardAudit::Operation::Audit.operations(source: "/app/operations/")
StandardAudit::Operation::Audit.undeclared            # => [Class, ...]
StandardAudit::Operation::Audit.unknown_actions       # => { Class => ["x.y"] }
StandardAudit::Operation::Audit.orphan_actions(within: ...)
StandardAudit::Operation::Audit.missing_write_sites   # declares but never writes
StandardAudit::Operation::Audit.unexpected_write_sites
StandardAudit::Operation::Audit.duplicate_catalogue_entries
```

A thin RSpec layer over exactly those predicates:

```ruby
require "standard_audit/rspec/operation"

RSpec.describe "Operation audit declarations" do
  it_behaves_like "standard_audit operation declarations",
    source:         "/app/operations/",
    minimum:        100,
    expected:       %w[Orders::CreateOperation],
    orphans_within: -> { AuditCatalogue::OPERATION_ACTIONS }
end
```

**Set `minimum:`.** It is the only example that fails when someone stops
including the module or eager loading stops reaching your operations — every
other example passes vacuously against an empty set. `orphans_within:` is the
catalogue slice operations own; pass it when your catalogue also covers writers
outside `app/operations/`, which would otherwise always look orphaned.

The registry can only see loaded classes, so the shared example calls
`Rails.application.eager_load!` by default (`eager_load: false` to opt out).

## Configuration Reference

Use `configure(baseline: true)` in your initializer. It remembers the block so
`StandardAudit.reset_configuration!` replays it — required if your suite loads
`standard_audit/rspec`, because the config object holds behaviour (`before_checksum`
hooks) as well as data, and a per-example reset would otherwise drop it.

```ruby
StandardAudit.configure(baseline: true) do |config|
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
  # Keys automatically stripped from metadata. Matching is EXACT on the key
  # name; there is deliberately no substring mode (see below).
  config.sensitive_keys += %i[my_custom_secret]  # added to built-in defaults

  # Regexps matched against every key name, in addition to the exact list.
  # Solves e.g. Stripe's `client_secret`, which does not equal `:secret`.
  config.sensitive_key_patterns = [/secret/i]

  # Keys (exact names or Regexps) that are never redacted, so a broad pattern
  # can keep the real audit keys it would otherwise swallow.
  config.sensitive_key_exceptions = %i[input_tokens output_tokens]

  # Descend into nested Hashes when redacting. OFF by default — without it,
  # `metadata: { stripe: { client_secret: ... } }` is written intact.
  config.filter_nested_metadata = true

  # -- Write-time hooks --
  # Run between the UUID assignment and the checksum computation, so a hook MAY
  # set a checksummed column and the row still passes `verify_chain`. No
  # `prepend: true` needed. Each hook is rescued individually and can never fail
  # the audit write. Not run on the batched `insert_all!` path.
  config.before_checksum { |log| log.scope = MyApp.derive_scope(log) }
  config.before_checksum :backfill_scope   # an AuditLog instance method

  # -- Operation audit contract (StandardAudit::Operation) --
  # Your action vocabulary, as a CALLABLE so Zeitwerk can reload it. nil (the
  # default) skips the membership check entirely.
  config.audit_catalogue = -> { AuditCatalogue::ACTIONS }

  # Whether `audit!` verifies declarations before writing. Callable or boolean;
  # defaults to local environments only.
  config.verify_audit_declarations = -> { Rails.env.local? }

  # Whether a failed audit WRITE aborts the operation. Default false (report and
  # swallow). Set true where an unaudited state change is a compliance failure.
  # DeclarationError always propagates regardless.
  config.raise_on_audit_write_error = false
  config.audit_write_error_handler = ->(error, action:, operation:) {
    ErrorReporting.notify(error, component: "operation_audit", audit_action: action)
  }

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

  # -- Retention (schedule StandardAudit::CleanupJob to enforce) --
  # Defaults from STANDARD_AUDIT_RETENTION_DAYS (see Retention below); set here
  # to override per app. Leave unset for infinite retention.
  config.retention_days = 90
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

## Retention

`config.retention_days` controls how long audit logs are kept. It is only
enforced when you actually run cleanup (the `StandardAudit::CleanupJob` or the
`standard_audit:cleanup` rake task) — setting it alone deletes nothing.

It defaults from the `STANDARD_AUDIT_RETENTION_DAYS` environment variable, so a
deployment can opt into a retention window without a code change:

```bash
STANDARD_AUDIT_RETENTION_DAYS=365   # keep 365 days
# unset / blank / 0 / negative / non-numeric => nil => infinite retention
```

Infinite retention (the default) is the compliance-safe behavior: nothing is
ever auto-deleted. For financial/legal domains that is usually what you want;
enabling a finite window is a deliberate decision.

### Production retention warning (StandardHealth)

`StandardAudit::Checks::Retention` is a [StandardHealth](https://github.com/rarebit-one/standard_health)-compatible
check that flags unbounded retention **on production deployments** as an
advisory. Register it (non-critical) in `config/initializers/standard_health.rb`:

```ruby
StandardHealth.configure do |c|
  c.register_check :audit_retention,
                   StandardAudit::Checks::Retention,
                   critical: false
end
```

When `APP_ENVIRONMENT == "production"` (falling back to `Rails.env.production?`
when that var is unset — so staging is not flagged) and `retention_days` is nil,
the check returns `:warn`. That rolls `GET /health/ready` up to `:degraded`,
which is **still HTTP 200** — it surfaces the advisory in the readiness JSON
without failing the probe or blocking a deploy. The check is duck-typed and has
no hard dependency on `standard_health`.

## Chain Integrity

Every row carries a SHA-256 `checksum` over its own fields **and the digest of
the row it was appended to**, so editing a row in place invalidates it. Each row
also records that parent explicitly in `previous_checksum`.

### The log is a DAG, not a strict line

A writer reads the current tip and links to it. That read is deliberately
unlocked, so two concurrent transactions — two Puma threads, a web request and a
job — can read the same tip and the sequence forks. **That is normal for a
multi-process writer, and it is not an integrity failure.** Forcing a strict
line would mean holding a lock until the enclosing business transaction commits
(a row is invisible to other writers until then, so releasing earlier reopens
the race), which serialises every audited request behind one mutex.

Storing the parent is what keeps a forked log verifiable: every row is checked
against the exact digest it signed, whether or not it is the walk's predecessor.
`previous_checksum` needs no protection of its own — it is an input to the row's
own digest, so editing it invalidates the row.

```ruby
result = StandardAudit::AuditLog.verify_chain
# => { valid: true, verified: 5577, recovered: 0, failures: [] }
```

- `failures` carries `reason: :digest_mismatch` (the row's fields no longer
  produce its digest) or `reason: :missing_parent` (the row it was appended to
  is no longer in the log). Retention pruning does not trip `:missing_parent`:
  if the walk opens on a row whose parent is already gone, that parent digest
  is exempt wherever else it appears — a pruned row can have several children.
  A removal from the *middle* is still reported. One caveat:
  `standard_audit:cleanup` prunes by `occurred_at` while the walk orders by
  `created_at`, so rows whose two timestamps disagree can leave a hole rather
  than a pruned start, and a hole is reported — truthfully, since rows really
  are missing.
- `recovered` counts rows with no `previous_checksum` whose parent had to be
  found by searching back through recent digests — see below.
- `verify_chain(scope: org)` skips the missing-parent check, because the log is
  global and a scoped row's parent usually belongs to another scope.

What this deliberately does **not** claim: that the log is in a single total
order, or that no row was inserted. A concurrent append and an inserted row look
alike, so a design that tolerates the first cannot detect the second. The
previous strict-line reading did not actually detect insertions either — it
reported every concurrent append as tampering, which on one production log meant
67% of rows red and any real signal lost in the noise.

### Rows written before 0.8.0

They have no `previous_checksum`. Verification falls back to the preceding row
in the walk and, failing that, searches back through the last `recovery_window`
(default 256) digests for the one that reproduces the row's checksum — which
recovers the true parent of a row that forked, **without re-signing anything**.
This does not weaken tamper detection: a row whose fields were altered
reproduces no candidate's digest. Pass `strict: true` to skip the search and see
every fork as a failure.

To make that permanent, add the column and record what each row was actually
signed against:

```bash
rails generate standard_audit:add_previous_checksum
rails db:migrate
rake standard_audit:relink_checksums
```

`relink_checksums` never rewrites a `checksum`. It fills in the previously-empty
`previous_checksum` only when that value reproduces the digest the row has held
since it was written, so it adds no attestation the rows did not already carry.
Rows it cannot resolve are reported as `unresolved` and keep failing
verification — which is the point.

**Do not run `backfill_checksums!` to make a red `verify_chain` go green.** It
re-signs rows from their current contents, so it attests only that a script ran.
It is for rows that never had a checksum at all (pre-feature data).

## Rake Tasks

```bash
# Verify chain integrity (exits non-zero on failures)
rake standard_audit:verify

# Record the parent digest each existing row was signed against
rake standard_audit:relink_checksums

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
config.sensitive_key_patterns = [/secret/i]         # catch a whole family
config.sensitive_key_exceptions = %i[input_tokens]  # ...minus the real ones
config.filter_nested_metadata = true                # redact nested Hashes too
```

`sensitive_keys` matches **exactly** on the key name. There is deliberately no
substring mode: against the default list it would strip real audit content —
`input_tokens` / `output_tokens`, `token_digest`, `password_reset_sent_at`,
`authorization_endpoint`, `onepassword`. Audit rows are append-only, so that
cannot be undone. Use `sensitive_key_patterns` and check any rule against your
own data first:

```bash
bin/rails "standard_audit:sensitive_keys:dry_run[secret]"   # NESTED=1 to model nesting
```

The dry run writes nothing. It reports per key what would be stripped, what
would be kept, and nested matches that survive because
`filter_nested_metadata` is off.

Nested metadata is **not** redacted unless `filter_nested_metadata` is enabled
— `metadata: { stripe: { client_secret: ... } }` passes both write paths under
exact matching by default.

**Performance**: For high-volume applications, enable async processing and ensure your `audit_logs` table has appropriate indexes (the install generator adds them by default). Consider partitioning by `occurred_at` for very large tables.

**Retention**: Set `retention_days` in your configuration and run `rake standard_audit:cleanup` via a scheduled job (e.g., cron or SolidQueue recurring). Archive before deleting if you need long-term storage.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
