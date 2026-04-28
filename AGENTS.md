# AGENTS.md - AI Agent Guide for StandardAudit

StandardAudit is a Rails engine providing database-backed audit logging via
`Rails.event` (Rails 8.1+) and `ActiveSupport::Notifications`. Audit records
land in a single `audit_logs` table with `GlobalID`-based polymorphic actor /
target / scope columns, optional async dispatch via ActiveJob, a tamper-evident
checksum chain, and GDPR-friendly anonymize / export helpers.

## Quick Reference

```bash
# Run the full spec suite
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/models/standard_audit/audit_log_spec.rb

# Lint
bundle exec rubocop

# Auto-fix lint issues
bundle exec rubocop -A

# Security checks
bundle exec brakeman --no-pager
bundle exec bundler-audit --update
```

The dummy app under `spec/dummy/` is in-memory SQLite; `spec/rails_helper.rb`
runs migrations on boot, so there is no separate `db:setup` step.

## Project Structure

```
standard_audit/
├── app/
│   ├── jobs/standard_audit/
│   │   ├── create_audit_log_job.rb   # Async insert path
│   │   └── cleanup_job.rb            # Retention cleanup
│   └── models/standard_audit/
│       ├── application_record.rb
│       └── audit_log.rb              # Core model + scopes + GDPR + checksum chain
├── lib/standard_audit/
│   ├── auditable.rb                  # Concern for actor/target models
│   ├── audit_scope.rb                # Concern for tenant/scope models
│   ├── configuration.rb              # Configuration object
│   ├── engine.rb                     # Wires subscribers at boot
│   ├── event_subscriber.rb           # Rails.event subscriber (8.1+)
│   ├── subscriber.rb                 # AS::Notifications subscriber
│   ├── presets/standard_id.rb        # Preset for StandardId events
│   ├── rspec.rb                      # RSpec auto-cleanup plugin
│   └── version.rb
├── lib/generators/standard_audit/
│   ├── install/                      # `rails g standard_audit:install`
│   └── add_checksums/                # Migration generator for checksum column
├── config/routes.rb
└── spec/
    ├── dummy/                        # Test Rails app (SQLite in-memory)
    ├── jobs/, models/, lib/, generators/
    ├── rails_helper.rb
    └── spec_helper.rb
```

## Key Patterns

### Configuration DSL

`StandardAudit.configure { |config| ... }` mutates a single
`StandardAudit::Configuration` instance held in `@configuration`. Settings
include subscriptions, extractors, `Current.*` resolvers, sensitive keys,
metadata builder, async flag, retention, and anonymizable keys. Tests can
call `StandardAudit.reset_configuration!` to drop the memoized config.

### Dual notification backend

The engine attaches two subscribers at boot:

- `StandardAudit::Subscriber` registers against `ActiveSupport::Notifications`
  for each pattern in `config.subscriptions`.
- `StandardAudit::EventSubscriber` is registered with `Rails.event.subscribe`
  on Rails 8.1+ when `Rails.event` is available. It uses the same
  subscription patterns but supports tags and `source_location`, stored under
  the reserved metadata keys `_tags` and `_source` (never filtered).

### GlobalID polymorphism

`AuditLog#actor=`, `#target=`, `#scope=` serialize records as GID strings and
remember `*_type`. The matching readers use `GlobalID::Locator.locate`. If
the underlying record was deleted, the reader returns `nil` but the GID and
type remain on the row.

### AuditLog model

- Append-only: `before_update` and `before_destroy` raise `ReadOnlyRecord`.
  GDPR helpers use `update_columns` to bypass.
- `before_create` assigns a UUIDv7 id and computes the row's checksum.
- `after_create_commit` instruments `standard_audit.audit_log.created`.
- Ships with a wide set of composable scopes (`for_actor`, `by_event_type`,
  `matching_event`, `today`/`this_week`/etc., `for_request`, `from_ip`,
  `chronological`, `recent(n)`).

### Batch + checksums

`StandardAudit.batch { ... }` buffers `record` calls in
`Thread.current[:standard_audit_batch]` and flushes via `insert_all!` on
block exit. Each row is given a UUIDv7 id (sorted to match insert order)
and chained checksum. `AuditLog.compute_checksum_value` hashes a canonical
serialisation of `CHECKSUM_FIELDS` plus the previous row's checksum;
`AuditLog.verify_chain` and `AuditLog.backfill_checksums!` walk the chain
in `(created_at, id)` order. Concurrent writers can fork the chain — see
the inline note on `compute_checksum`.

### Auditable concern

`include StandardAudit::Auditable` adds `audit_logs_as_actor`,
`audit_logs_as_target`, `audit_logs`, and a `record_audit(event_type, ...)`
shortcut that calls `StandardAudit.record(actor: self, ...)`.

### AuditScope concern

`include StandardAudit::AuditScope` adds `scoped_audit_logs` to
tenant/organisation models so you can fetch all activity within a scope.

### Subscribing to gem events

`config.subscribe_to(pattern)` accepts a string, glob, or `Regexp`. Each
event-publishing gem documents its own event namespace; the host app
subscribes to whatever patterns it wants audited:

```ruby
config.subscribe_to "standard_id.authentication.*"
config.subscribe_to "standard_id.session.created"
config.subscribe_to "standard_circuit.circuit.*"
```

This gem deliberately has no knowledge of specific publisher gems —
keeping the dependency direction one-way (publishers don't know about
audit; audit doesn't know about specific publishers).

### GDPR methods

- `AuditLog.anonymize_actor!(record)` — replaces `actor_gid`/`target_gid`
  with `[anonymized]` where the record appears, clears `ip_address`,
  `user_agent`, `session_id`, and strips
  `config.anonymizable_metadata_keys` from `metadata`.
- `AuditLog.export_for_actor(record)` — returns a `{ subject:, exported_at:,
  total_records:, records: [...] }` hash for a "right to access" request.

## Database Tables

| Table        | Purpose                                                   |
|--------------|-----------------------------------------------------------|
| `audit_logs` | Single table, UUIDv7 PK, JSON metadata, polymorphic GIDs, optional `checksum` for tamper-evidence |

## Common Workflows

### Recording an event

1. Prefer `Rails.event.notify(...)` on Rails 8.1+ — context (request_id,
   ip_address, user_agent, session_id) is captured automatically when the
   host app calls `Rails.event.set_context(...)`.
2. Use `StandardAudit.record("event.name", actor:, target:, scope:, metadata:)`
   for direct calls.
3. Use `ActiveSupport::Notifications.instrument("event.name", payload)` on
   older Rails.
4. Wrap a unit of work in `StandardAudit.record(...) { ... }` for the block
   form (instruments via AS::Notifications and only records on success).

### Async processing

Set `config.async = true` (and optionally `config.queue_name = :audit`).
`StandardAudit::CreateAuditLogJob` is enqueued instead of writing inline,
serialising actor/target/scope as GID strings and resolving them inside
`perform`.

## Testing

- `spec/dummy/` is a complete Rails app booted with in-memory SQLite. The
  migrations under `spec/dummy/db/migrate/` create both `audit_logs` and the
  test models used by the suite.
- No FactoryBot — specs build records inline.
- Auto-cleanup plugin: `require "standard_audit/rspec"` to install a
  `before(:each)` hook that clears the thread-local batch buffer and resets
  the memoized configuration so per-example mutations do not leak.
- `shoulda-matchers` is loaded for `should validate_presence_of` style.
- `ActiveSupport::Testing::TimeHelpers` is included globally.

## Security Notes

- Audit rows are append-only — `update`/`destroy` raise `ReadOnlyRecord`.
  GDPR anonymization deliberately uses `update_columns` to bypass this.
- `RESERVED_METADATA_KEYS = %w[_tags _source]` are never filtered, even if
  the consumer adds them to `sensitive_keys`.
- Default `sensitive_keys` cover password / token / secret / api_key /
  access_token / refresh_token / private_key / certificate_chain / ssn /
  credit_card / authorization. The `:authorization` key filters HTTP
  Authorization header values; rename policy-decision keys to avoid
  accidental filtering (e.g. `:authorization_policy`).
- Checksum chain provides tamper-evidence but is best-effort under
  concurrent writes — use a DB advisory lock if serialisable chain
  integrity is required.
- `bundle exec brakeman --no-pager` and `bundle exec bundler-audit --update`
  run as part of the pre-push lefthook checks.

## Key Files

| File                                                | Purpose                                         |
|-----------------------------------------------------|-------------------------------------------------|
| `lib/standard_audit.rb`                             | Public API: `record`, `batch`, `configure`      |
| `lib/standard_audit/configuration.rb`               | Configuration object + presets dispatcher       |
| `lib/standard_audit/engine.rb`                      | Wires subscribers at boot                       |
| `lib/standard_audit/subscriber.rb`                  | `AS::Notifications` subscriber                  |
| `lib/standard_audit/event_subscriber.rb`            | `Rails.event` subscriber (8.1+)                 |
| `lib/standard_audit/rspec.rb`                       | RSpec auto-cleanup plugin                       |
| `app/models/standard_audit/audit_log.rb`            | Core model, scopes, checksum chain, GDPR        |
| `app/jobs/standard_audit/create_audit_log_job.rb`   | Async write path                                |
| `app/jobs/standard_audit/cleanup_job.rb`            | Retention cleanup                               |
| `lib/generators/standard_audit/install/`            | Install generator (migration + initializer)     |

## Dependencies

- **activerecord**, **activejob**, **activesupport** — `>= 7.1`
- **globalid** — `>= 1.0` (polymorphic references)

Dev / test:

- **rspec-rails**, **shoulda-matchers** — test framework
- **rubocop-rails-omakase** — linting
- **brakeman**, **bundler-audit** — security scanners
- **simplecov** — coverage reporting (no minimum threshold)
