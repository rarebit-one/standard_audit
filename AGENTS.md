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
│   ├── metadata_filter.rb            # Sensitive-key redaction (both write paths)
│   ├── sensitive_keys_dry_run.rb     # Read-only "what would this rule strip?"
│   ├── reference_preloading.rb       # Batch actor/target/scope GID resolution
│   ├── event_subscriber.rb           # Rails.event subscriber (8.1+)
│   ├── subscriber.rb                 # AS::Notifications subscriber
│   ├── operation.rb                  # Operation audit DSL (audits / audit_none! / audit!)
│   ├── operation/audit.rb            # Registry, catalogue, policy, meta-spec predicates
│   ├── rspec.rb                      # RSpec auto-cleanup plugin
│   ├── rspec/operation.rb            # Shared examples over Operation::Audit
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
include subscriptions, extractors, `Current.*` resolvers, sensitive keys +
patterns + exceptions, nested filtering, metadata builder,
`before_checksum` hooks, async flag, retention, and anonymizable keys.
`StandardAudit.reset_configuration!` drops the memoized config.

**Any new Configuration field must be in the `attr_accessor` list AND
defaulted in `initialize`**, or the rspec plugin's per-example reset leaves
it nil.

`StandardAudit.configure(baseline: true) { ... }` additionally *remembers*
the block, and `reset_configuration!` replays it. Host initializers should
always use it, and the install template does. The config object holds
**behaviour**, not just data — `before_checksum_hooks` live there — so a
suite that installs `standard_audit/rspec` without a baseline silently
loses its write-time hooks after the first example, and the specs that
would notice pass vacuously. `reset_configuration!(replay_baseline: false)`
and `clear_baseline_configuration!` exist for the gem's own specs.

### Operation audit contract

`StandardAudit::Operation` is the DSL that was independently written in all
five consumer apps and extracted in 0.9.0. Non-negotiable design points, each
of which a host depended on:

- **It is a module, never a base class.** The five host `ApplicationOperation`
  classes range 61–303 lines and diverge deliberately — one explicitly refuses
  a `Result`/`execute` lifecycle, and one app has no shared base at all. This
  module contributes the audit contract and nothing else. **Never add a
  lifecycle to it.**
- **Two adoption shapes, no host configuration.** A shared base including it
  once (leaves registered via `inherited`), and leaves including it directly
  (via `included`). The unifier is that a class which declares NOTHING and HAS
  subclasses is treated as a base and excluded. A class that *did* declare is
  never excluded that way, so subclassing a real operation cannot silently drop
  it from the check. The rule only sees LOADED subclasses, hence the
  eager-load in the shared examples.
- **`@audit_spec` is a class-level ivar and is deliberately NOT inherited.** A
  leaf inheriting its parent's declaration would pass the meta-spec while
  writing nothing.
- **The catalogue is host-declared, and a callable.** The gem has no knowledge
  of any publisher gem's or app's vocabulary. A callable, not a constant,
  because eagerly referencing an autoloadable constant from an initializer
  breaks Zeitwerk reloading. `nil` = check skipped.
- **Membership is the only validation.** No dot-count, case, prefix, or
  namespace rule — one host's catalogue carries notification-bus names
  verbatim, and normalising them would orphan historical rows.
- **`DeclarationError` always re-raises**, ahead of any generic rescue and
  regardless of `raise_on_audit_write_error`. Write failures follow
  `raise_on_audit_write_error` (default false); it exists because one app
  deliberately does not rescue, and a swallow-only module would have silently
  downgraded its compliance posture.
- The meta-spec logic lives in **plain-Ruby predicates** on
  `StandardAudit::Operation::Audit`; `standard_audit/rspec/operation` is a thin
  shared-example layer with no logic of its own. The `minimum:` registry floor
  is the one example that catches "someone stopped including the module" —
  every other example passes vacuously against an empty set.

### before_checksum hooks

`config.before_checksum { |log| ... }` (or `config.before_checksum
:some_instance_method`) registers a hook that runs on `before_create`
**between `assign_uuid` and `compute_checksum`**. Definition order is
execution order, so a hook may set a `CHECKSUM_FIELDS` member — back-fill
`scope`, derive a column, rewrite `metadata` — and the row still passes
`verify_chain`. That is exactly what hosts were buying with their own
`before_create ..., prepend: true`, and they no longer need it.

**Do not reorder those three `before_create` lines in `audit_log.rb`.**

Each hook is rescued individually: a failing hook logs (and reports to
`Rails.error`), is **rolled back to the attributes it started from**, and is
skipped — it never fails the audit write. The rollback matters: without it a
hook that assigns `scope_gid` and then fails a later lookup would leave a
half-applied row that the following callbacks checksum and persist, so the
hook would not really be "skipped".

If a row is created with an explicit `checksum`, hooks still run (most
derived columns aren't checksummed), but the supplied checksum is dropped
and re-derived if a hook changed a `CHECKSUM_FIELDS` member — otherwise the
row would fail `verify_chain` on arrival.

Hooks do not run on the batched `insert_all!` path.

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
remember `*_type`. The matching readers consult a per-row preload memo, then
fall back to `GlobalID::Locator.locate`. If the underlying record was deleted,
the reader returns `nil` but the GID and type remain on the row.

`#actor_model_id` / `#target_model_id` / `#scope_model_id` return the trailing
gid segment. Deliberately not `GlobalID.parse(gid)&.model_id` — audit gids are
historical, so a gid whose app segment differs from the current `GlobalID.app`
is still a real row. The trailing segment is app-name agnostic.

### Batch reference preloading

`AuditLog.preload_references(logs, refs: %i[actor target], only: [...],
includes: {...})` resolves a whole page in one query per distinct stored
`*_type`, then memoizes onto each row. `preloaded_actor=` /
`preloaded_target=` / `preloaded_scope=` are the public writers.

- The memo is a Hash consulted with `key?`, so **preloaded-but-deleted
  memoizes `nil` and reads back without a query** — distinct from
  not-preloaded. `#actor_preloaded?` reports which.
- `actor=` / `target=` / `scope=` populate the memo (they hold the record);
  `reload` clears it.
- `only:` is matched against the **stored type string by class name**, not via
  `GlobalID`'s `gid.model_class <= klass` (which constantizes *before*
  filtering, so a renamed historical class raises `NameError` instead of being
  denied). It therefore does not expand to subclasses or modules — list every
  concrete class. Non-whitelisted references memoize `nil`.
- `includes:` is per-type when every Hash key is a String or Class
  (`{ "Order" => [:user] }`); anything else is a uniform includes spec.

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
block exit. **`insert_all!` bypasses Active Record entirely** — no model is
instantiated, so `before_create` callbacks, the checksum callback, and the
reference-preload memo all do not run on that path (the batch path computes
checksums itself). A host callback that must apply to batched rows has to set
the column on the buffered attrs, not in a model hook. Each row is given a
UUIDv7 id (sorted to match insert order) and chained checksum. `AuditLog.compute_checksum_value` hashes a canonical
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
  the memoized configuration so per-example mutations do not leak. Adopting
  it **requires** the host initializer to use `configure(baseline: true)` —
  otherwise the reset drops the app's real configuration, `before_checksum`
  hooks included.
- `shoulda-matchers` is loaded for `should validate_presence_of` style.
- `ActiveSupport::Testing::TimeHelpers` is included globally.

## Security Notes

- Audit rows are append-only — `update`/`destroy` raise `ReadOnlyRecord`.
  GDPR anonymization deliberately uses `update_columns` to bypass this.
- **One filter, two write paths.** `StandardAudit::MetadataFilter` is the only
  implementation of sensitive-key redaction; `StandardAudit.record` and
  `Subscriber#extract_metadata` both call it. They used to carry independent
  copies which had already diverged (the subscriber copy did not subtract
  `RESERVED_METADATA_KEYS`). The parity is driven from one shared example —
  `spec/support/shared_examples/metadata_filtering.rb` — so a future
  divergence fails the suite. Do not reintroduce a local `sensitive_keys`
  reject anywhere. The filter **fails closed**: hash-like input that isn't a
  `Hash` (e.g. `ActionController::Parameters`) is still filtered, and input it
  cannot filter raises rather than being written unredacted.
- `RESERVED_METADATA_KEYS = %w[_tags _source]` are never filtered, even if
  the consumer adds them to `sensitive_keys`.
- Matching is **exact, on the key name**, string/symbol-insensitive, plus any
  Regexp in `config.sensitive_key_patterns`. `config.sensitive_key_exceptions`
  (exact names or Regexps) always wins.
- **There is no substring matching mode, and do not add one.** Against the
  default key list, substring matching strips real audit content across the
  estate: `input_tokens` / `output_tokens` (live LLM cost accounting in
  luminality and sidekick), `token_digest` (rendered in luminality's staff
  audit UI), `password_reset_sent_at`, `authorization_endpoint`, and even
  `onepassword`. **Audit rows are append-only, so it cannot be undone** — the
  content is simply never written from then on. `sensitive_key_patterns` is the
  supported tool: `/secret/i` solves the motivating `client_secret` case, and
  it is opt-in per app.
- **Nested metadata is unfiltered unless `config.filter_nested_metadata` is
  true.** By default `metadata: { stripe: { client_secret: … } }` is written
  intact on *both* write paths, even under exact matching. Turning it on
  descends into nested Hashes and Hashes inside Arrays. Reserved keys are
  preserved *and their subtree is never descended into, at any depth* —
  `_tags` / `_source` are gem-owned, not host payload.
- Before enabling any rule, run it against real rows:
  `rake "standard_audit:sensitive_keys:dry_run[secret]"` (`NESTED=1` to model
  nested filtering). It reports per key what would be stripped, what would be
  kept, and nested matches that survive because nested filtering is off. Keys
  are extracted **in Ruby, never with `jsonb_object_keys`** — the install
  template ships jsonb + GIN but the gem stays backend-neutral (the dummy is
  SQLite).
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
| `lib/standard_audit/configuration.rb`               | Configuration object                            |
| `lib/standard_audit/engine.rb`                      | Wires subscribers at boot                       |
| `lib/standard_audit/metadata_filter.rb`             | Sensitive-key redaction, shared by both paths   |
| `lib/standard_audit/sensitive_keys_dry_run.rb`      | Read-only redaction-rule dry run                |
| `lib/standard_audit/subscriber.rb`                  | `AS::Notifications` subscriber                  |
| `lib/standard_audit/event_subscriber.rb`            | `Rails.event` subscriber (8.1+)                 |
| `lib/standard_audit/reference_preloading.rb`        | Batch actor/target/scope GID resolution + memo   |
| `lib/standard_audit/operation.rb`                   | Operation audit DSL — a module, never a base class |
| `lib/standard_audit/operation/audit.rb`             | Registry, catalogue resolver, write-error policy, predicates |
| `lib/standard_audit/rspec.rb`                       | RSpec auto-cleanup plugin                       |
| `lib/standard_audit/rspec/operation.rb`             | Shared examples over `Operation::Audit`         |
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
