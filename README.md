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

When `actor` is omitted, it falls back to the configured `current_actor_resolver` (which reads `Current.account`, then `Current.user`, by default).

#### Non-fatal writes: `raise: false`

Where a missing audit row must never break the request — logging an
authentication failure, say — pass `raise: false`. A failed write is logged,
reported through `config.error_reporter` (default: `Rails.error`, as handled;
context `{ <audit_error_context_key> => event_type, source: "StandardAudit.record" }`),
and `record` returns nil:

```ruby
StandardAudit.record("auth.token_invalid",
  actor: token,
  metadata: { error_code: "AUTH_001", path: request.path },
  raise: false)
```

The default is `raise: true` (unchanged). In block form the option only
governs the audit write; errors from your block always propagate.

#### Where swallowed failures go: `config.error_reporter`

By default the gem reports every error it swallows with
`Rails.error.report(error, handled: true, context:)`. That covers a failed
`record(raise: false)`, a failed subscriber write, a raising `before_checksum`
hook, and a failed `audit!` write under the default policy. It reaches your
error tracker only if something subscribes to `Rails.error`. `sentry-rails`
registers that subscriber for you. If your app never forwards `Rails.error`
(a hand-rolled Sentry setup), point the gem straight at the tracker (0.13.0+):

```ruby
config.error_reporter = ->(error, context) { Sentry.capture_exception(error, extra: context) }
```

It receives the error and the context Hash (keyed by
`audit_error_context_key`) and **replaces** the `Rails.error` call. If you want
both, call `Rails.error.report` from it too. A reporter that raises is logged
and ignored, so it can never turn a swallowed audit failure into a raised one.
`audit_write_error_handler`, when set, still takes precedence for `audit!`
write failures.

**Replace your host code with** `config.error_reporter`. It supersedes any
rescue-and-report wrapper kept around `record(raise: false)` or `audit!` only
because the app does not forward `Rails.error` to its tracker.

**Replace your host code with** `raise: false`. It supersedes the
`AuditAuthFailure#record_auth_failure` rescue-and-report wrapper
(sidekick-web, luminality-web, nutripod-web
`app/controllers/concerns/audit_auth_failure.rb`); set
`config.audit_error_context_key = :audit_event` to keep those apps' Sentry
grouping key.

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

### One write path, and `before_write`

Every entry point — `StandardAudit.record` (plain and block form),
`Auditable#record_audit`, `Operation#audit!`, the ActiveSupport::Notifications
subscriber and the `Rails.event` subscriber — ends in the same write path.
Actor/session/scope resolution, `metadata_builder`, `before_write`, record
dereferencing, redaction, `StandardAudit.batch` and `async` therefore behave
identically whichever way a row is written. (Before 0.12.0 the notifications
subscriber carried its own copy: it ignored `batch`, and `metadata_builder`
never ran on direct `record` calls.)

`config.before_write` is the seam for host policy that must apply to every row:

```ruby
config.before_write = ->(entry) {
  # entry: { event_type:, actor:, target:, scope:, metadata:,
  #          request_id:, ip_address:, user_agent:, session_id:, via: }
  metadata = entry[:metadata]
  AuditMetadataPii.verify!(metadata) if StandardAudit::Operation::Audit.verify? && entry[:via] == :direct
  metadata = AuditMetadataPii.mask(metadata)
  metadata = metadata.merge(surface: Current.audit_surface) if Current.audit_surface.present?
  entry[:metadata] = metadata
}
```

**Order, per write:** `Current` resolvers → `metadata_builder` → `before_write`
→ record dereferencing → `sensitive_keys` redaction → persist (or buffer, or
enqueue). So:

- `before_write` **sees the builder's output, not the raw metadata.** If your
  `metadata_builder` masks or rewrites values, a guard in `before_write` checks
  the masked values and can never fire. Keep the builder to idempotent
  injection (like `engine_scope`), and do guard-then-mask in `before_write`, in
  that order, as above. Before 0.13 this README showed a guard in
  `before_write` next to a masking builder, which does not work.
- Anything `before_write` injects is still dereferenced and redacted.

Mutate `entry` in place; the return value is ignored. Raising aborts the write:
direct callers see the error, the subscribers rescue and report it.

**`entry[:via]`** (0.13.0+) names the entry point, so a hook can treat direct
writes differently from subscriber writes. For example, it can apply a guard
only to rows your own code writes and not to payloads a gem publishes. It is
not persisted.

| `entry[:via]` | Written by |
|---|---|
| `:direct` | `StandardAudit.record` (no block), `Auditable#record_audit`, `Operation#audit!` |
| `:notification` | the ActiveSupport::Notifications subscriber (`subscribe_to` patterns), including `StandardAudit.record` **with a block** |
| `:rails_event` | the `Rails.event` subscriber (Rails 8.1+) |

**Hooks run once per row, batched writes included.** `before_write` and
`before_checksum` run for every row inside `StandardAudit.batch` too (at flush
time for `before_checksum`). A hook that looks something up per actor (a role,
a membership, a tenant) therefore runs one query per row and turns a batch into
an N+1. Memoize those lookups for the unit of work, for example in a
`CurrentAttributes` cache that resets with the request or job:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :audit_actor_roles

  def self.audit_role_for(actor)
    self.audit_actor_roles ||= {}
    audit_actor_roles[actor.to_global_id.to_s] ||= actor.audit_role
  end
end

# actor_role: a column your app added to audit_logs
config.before_checksum { |log| log.actor_role = Current.audit_role_for(log.actor) if log.actor }
```

**Replace your host code with** a `before_write`. It supersedes:

- a hand-built job-side wrapper that runs a guard before `StandardAudit.record`
  (fundbright-web `AuditWriting#record_audit!`);
- an `audit!` override that runs a PII guard and injects metadata
  (fundbright-web `ApplicationOperation#audit!`);
- a `metadata_builder` whose injection (`engine_scope`) is documented as
  missing direct writes (fundbright-web / luminality-web initializers) —
  `metadata_builder` now applies to direct writes too, so no change is needed
  beyond deleting the caveat.

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

## Testing

```ruby
# spec/rails_helper.rb
require "standard_audit/rspec"
```

This resets StandardAudit state before every example (so declare your
configuration with `configure(baseline: true)`), and loads two helpers. Each is
also loadable on its own: `standard_audit/rspec/matchers`,
`standard_audit/rspec/baseline`.

### `have_audited`

```ruby
expect { Orders::Create.call(order) }
  .to have_audited("order.created")
  .by(account)                    # a record, an RSpec matcher, or no arg = "any resolvable actor"
  .on(order)                      # target, same forms
  .within(organisation)           # scope, same forms
  .with_metadata(total: 100, tags: include("vip"))  # subset; values may be matchers
  .once                           # or .times(n); default "at least one"

expect { noop }.not_to have_audited("order.created")
```

Only rows persisted during the block count. On failure it lists the rows that
were written, so a wrong actor or metadata shows up directly.

**Replace your host code with** `have_audited`. It supersedes hand-rolled
helpers such as `expect_well_formed_audit(action)` (sidekick-web
`spec/support/audit_log_coverage.rb`) — the equivalent is
`have_audited(action).by.on` — and the
`change(StandardAudit::AuditLog, :count)` + `AuditLog.last` pairs across the
five apps' coverage specs.

### `"a standard_audit baseline"`

Guards that your configuration survives the per-example reset:

```ruby
RSpec.describe "StandardAudit configuration baseline" do
  it_behaves_like "a standard_audit baseline",
    subscriptions: [/\Astandard_id\./, /\Aauthorization\./],
    settings: { retention_days: 1826, raise_on_audit_write_error: true, filter_nested_metadata: true },
    catalogue: -> { AuditCatalogue::ACTIONS },
    sensitive_keys: %i[source_payload],
    sensitive_key_patterns: [/secret/i],
    present: %i[metadata_builder before_write current_scope_resolver],
    hooks: 2 # before_checksum hooks: a count, or %i[backfill_scope] by name
end
```

It checks the baseline is registered, that each value holds, and that it is
restored after a mutation plus `reset_configuration!`. Behaviour held in
lambdas can only be checked for presence; keep an app-specific example for
anything whose *result* matters.

`hooks:` (0.13.0+) covers `before_checksum` hooks, which a reset drops unless
the baseline re-adds them. Pass an Integer to require exactly that many, or an
Array of Symbol hook names (`config.before_checksum :name`) to require each one.
The mutation example clears the hooks before the reset, so a hook registered
outside the baseline block fails it. This replaces hand-written "still carries
the N hooks after a reset" examples.

**Replace your host code with** the shared example. It supersedes the bulk of
each app's `spec/initializers/standard_audit_baseline_spec.rb` (or
`spec/config/…`). The `Current.account` / `Current.session&.id` resolver
examples can go too once those overrides are deleted (they are the 0.12.0
defaults).

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
  # (Defaults shown in simplified form — each is respond_to?-guarded.)
  config.current_actor_resolver      = -> { Current.account || Current.user }
  config.current_request_id_resolver = -> { Current.request_id }
  config.current_ip_address_resolver = -> { Current.ip_address }
  config.current_user_agent_resolver = -> { Current.user_agent }
  config.current_session_id_resolver = -> { Current.session&.id || Current.session_id }

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

  # Replace ActiveRecord objects in metadata with a reference instead of
  # serialising every attribute. ON by default; see "Records in metadata".
  config.dereference_record_metadata = true

  # -- Write-time hooks --
  # Run between the UUID assignment and the checksum computation, so a hook MAY
  # set a checksummed column and the row still passes `verify_chain`. No
  # `prepend: true` needed. Each hook is rescued individually and can never fail
  # the audit write. Also run on batched writes, at flush time (since 0.12.0).
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
  # Optional proc to transform metadata before storage. Runs on EVERY write
  # path (since 0.12.0 — previously only the two subscribers).
  config.metadata_builder = ->(metadata) { metadata.slice(:relevant_key) }

  # -- Ambient scope --
  # Fallback tenant when a write names none. See "Multi-Tenancy".
  config.current_scope_resolver = -> { Current.organisation }

  # -- before_write --
  # Runs on every write path, after metadata_builder and before redaction.
  # entry[:via] is :direct, :notification or :rails_event. See "One write path".
  config.before_write = ->(entry) { entry[:metadata] = entry[:metadata].merge("surface" => Current.surface) }

  # -- Error reporting --
  # Where swallowed audit failures go. nil (default) = Rails.error.report.
  # config.error_reporter = ->(error, context) { Sentry.capture_exception(error, extra: context) }

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

Out of the box, StandardAudit reads from a top-level `Current` if it responds to the relevant method:

| Column       | Default resolution (first non-nil wins)          |
|--------------|--------------------------------------------------|
| actor        | `Current.account`, then `Current.user`           |
| session_id   | `Current.session&.id`, then `Current.session_id` |
| request_id   | `Current.request_id`                             |
| ip_address   | `Current.ip_address`                             |
| user_agent   | `Current.user_agent`                             |

The `account`/`session` pair is what StandardId's `Current` exposes, so a StandardId app gets actor and session attribution with zero configuration (since 0.12.0 — earlier versions read only `Current.user`/`Current.session_id`, which StandardId does not define). Apps following the Rails generator convention (`Current.user`) keep working unchanged.

**Replace your host code with:** nothing. If your initializer carries

```ruby
config.current_actor_resolver = -> { Current.account }
config.current_session_id_resolver = -> { Current.session&.id }
```

both lines are now the defaults and can be deleted.

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

### Ambient scope: `current_scope_resolver`

When most writes happen inside a tenant-scoped request, resolve the scope from
`Current` instead of threading it through every call:

```ruby
config.current_scope_resolver = -> { Current.channel || Current.organisation }
```

It is a *fallback*: an explicit `scope:` and a scope found by `scope_extractor`
always win. It applies on every write path (direct `record`, `audit!`,
`record_audit`, both subscribers; sync, async and batched). Default `nil`.

`current_scope_resolver` is for scope that comes from **ambient request
state** (`Current`). It takes no arguments and never sees the row. Scope that
derives from the **row itself**, such as the organisation that owns the
target, belongs in a `before_checksum` hook (or `before_write`), which receives
the record or entry:

```ruby
config.before_checksum do |log|
  log.scope ||= log.target.organisation if log.target.respond_to?(:organisation)
end
```

**Replace your host code with** the one line above when your fallback reads
`Current`. It supersedes a `scope_extractor` that falls back to `Current`
(nutripod-web:
`->(payload) { payload[:scope] || Current.channel || Current.organisation }`),
which only ever covered the subscriber path. Keep `scope_extractor` for reading
the payload and move the `Current` fallback here. Target-derived scope hooks
stay as they are; since 0.12.0 they also run on the batched path.

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

Both `anonymize_actor!` and `export_for_actor` accept the subject as a record,
a `GlobalID`, or a GlobalID string (`"gid://myapp/User/123"`). A string is
parsed, never located, so erasure still works after the user's own row has been
deleted — the usual order for an erasure request. Anything that is not a valid
GlobalID raises `ArgumentError`.

```ruby
StandardAudit::AuditLog.anonymize_actor!("gid://myapp/User/123")
```

#### Anonymization and the checksum chain

Anonymizing rewrites checksummed columns, so an anonymized row can no longer
reproduce its own digest. Since 0.12.0 its stored `checksum` is left untouched
(the rows after it still link to it) and, when the table has an
`anonymized_at` column, the row is stamped. `verify_chain` then counts it under
`redacted` instead of reporting a `digest_mismatch`:

```ruby
StandardAudit::AuditLog.verify_chain
# => { valid: true, verified: 5576, recovered: 0, reordered: 0, redacted: 1,
#      legacy_unverifiable: 0, failures: [] }
```

A redacted row's declared parent is still checked, so deleting the row before
it is still reported as `missing_parent`. Reconcile a nonzero `redacted`
against your erasure records: anyone who can write `anonymized_at` can hide an
edit behind it.

Existing installs add the column with:

```bash
rails generate standard_audit:add_anonymized_at
rails db:migrate
```

(nullable, no default, idempotent; safe under strong_migrations). Without it,
`anonymize_actor!` works exactly as before and anonymized rows keep failing
`verify_chain` as `digest_mismatch`. Rows anonymized before the migration are
not stamped retroactively — they are indistinguishable from tampered rows after
the fact; stamp them by hand if your erasure log identifies them.

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
ever auto-deleted. The `standard_audit:cleanup` and `standard_audit:archive`
rake tasks respect this: with no days argument and a nil `retention_days` they
abort rather than fall back to a default window. For financial/legal domains that is usually what you want;
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
# => { valid: true, verified: 5577, recovered: 0, reordered: 0, redacted: 0,
#      legacy_unverifiable: 0, failures: [] }
```

`redacted` counts rows anonymized by `anonymize_actor!` — see "Anonymization
and the checksum chain".

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
  Legacy (pre-0.14) rows can also carry `reason: :legacy_key_order_unverifiable`,
  and a row marked with an unknown `checksum_version` carries
  `reason: :unsupported_checksum_version` — see "Checksum algorithm versions".
- `recovered` counts rows with no `previous_checksum` whose parent had to be
  found by searching back through recent digests — see below.
- `reordered` and `legacy_unverifiable` concern legacy rows only — see
  "Checksum algorithm versions".
- `verify_chain(scope: org)` skips the missing-parent check, because the log is
  global and a scoped row's parent usually belongs to another scope.

What this deliberately does **not** claim: that the log is in a single total
order, or that no row was inserted. A concurrent append and an inserted row look
alike, so a design that tolerates the first cannot detect the second. The
previous strict-line reading did not actually detect insertions either — it
reported every concurrent append as tampering, which on one production log meant
67% of rows red and any real signal lost in the noise.

### Checksum algorithm versions

Up to 0.13.x the digest hashed `metadata.to_json` in the order the Ruby hash
was built. PostgreSQL `jsonb` (and MySQL `JSON`) store object keys in their own
order — shortest first, then bytewise — so a row whose metadata had more than
one key could only be verified if its keys happened to be written in that
order. On one production log that was 67% of rows
([fundbright/delivery-ops#689](https://github.com/fundbright/delivery-ops/issues/689)).
SQLite keeps JSON as text in insertion order, so the gem's own suite never saw
it; CI now runs the suite on PostgreSQL too.

| Version | Written by | Digest |
|---------|------------|--------|
| 1 (legacy) | ≤ 0.13.x | `SHA256("<parent>\|field=value\|…")`, Hash values via `to_json` in Ruby key order. Kept byte-for-byte so old rows verify as they were signed. |
| 2 (canonical) | ≥ 0.14.0 | `SHA256` of canonical JSON `{"fields": {…}, "previous_checksum": …, "v": 2}`: JSON values round-tripped exactly as the column stores them, object keys sorted bytewise at every depth, integral floats as integers, times as UTC ISO 8601 (µs), nil distinct from `""`, no separator ambiguity, the version itself hashed. |

`StandardAudit::Checksum` holds both; `AuditLog#compute_checksum_value(version:)`
selects one (default: 2).

**The version column.** `rails g standard_audit:add_checksum_version` adds a
nullable `checksum_version` (0.14+ installs have it). New rows are stamped `2`;
existing rows stay `NULL` — nothing is backfilled, because stamping a version
onto a row claims something about how it was signed that nobody checked. The
version is hashed into a v2 digest, so it cannot be edited to change how a row
is judged. Without the column, 0.14 still *writes* v2 digests, but cannot mark
them, so every row has to be tried both ways and a tampered new row with
multi-key metadata is indistinguishable from a legacy one. Install the column.

**How `verify_chain` judges each row:**

| Row | Checked as | Outcome when it does not reproduce |
|-----|------------|------------------------------------|
| `checksum_version = 2` | v2 only (declared parent, else preceding row, else the recovery search) | `:digest_mismatch`. Never classified as legacy. |
| `checksum_version` NULL / no column | v1, then v2 — with the same parent rules and recovery search | the key-order search below |
| any other value | — | `:unsupported_checksum_version` |

For an unmarked row that neither version reproduces:

1. **Key-order reconstruction.** The insertion order v1 hashed cannot be read
   back — jsonb's order depends only on the key set, so every insertion order
   stores identically — but it can be *searched*. If some ordering of the
   stored keys (at every depth), hashed with the row's parent, reproduces the
   digest the row has held since it was written, that is a witness in the same
   sense as the parent recovery search: a row whose values were edited
   reproduces no ordering. Such rows count in `reordered` and are valid. The
   search enumerates at most `key_order_search_limit:` orderings per row
   (default 720, i.e. six keys in one object), tries orders learned from
   earlier rows with the same keys first (an event is usually built by one
   code path, so most rows cost one hash), and tries the declared parent — or,
   without one, the preceding row and "no parent". It is not combined with the
   256-row recovery window.
2. **`:digest_mismatch`** when the search was exhaustive against the parent the
   row *declares*: no key order explains the row, so its content does not
   match what was signed. Also for any row with no multi-key object — key order
   cannot be why it fails.
3. **`:missing_parent`** when its declared parent is gone.
4. **`:legacy_key_order_unverifiable`** otherwise — a row with a multi-key
   object whose order could not be reconstructed (more orderings than the
   limit, or no declared parent), and every other check passed.

**What `valid` means.** `valid` is `failures.empty?`, as before, and
`:legacy_key_order_unverifiable` rows **are failures by default**: "cannot be
proven either way" is not "untampered" — an edited legacy row looks exactly
like one whose key order was lost. Whether to accept them is a policy decision
for the host, and `verify_chain` makes it explicit:

```ruby
StandardAudit::AuditLog.verify_chain(accept_legacy_unverifiable_before: Time.utc(2026, 9, 26))
# => { valid: true, legacy_unverifiable: <n>, failures: [], … }
```

Rows created before that time are left out of `failures` and only counted in
`legacy_unverifiable`; rows created at or after it are always failures. Pick
the time the upgrade finished deploying: it also stops a post-upgrade row from
being passed off as legacy by clearing its `checksum_version`. The rake task
takes `ACCEPT_LEGACY_UNVERIFIABLE_BEFORE=<ISO 8601>` and
`KEY_ORDER_SEARCH_LIMIT=<n>`.

**Cost.** A v2 row costs one JSON round trip and one hash. A legacy row that
needs the search costs up to `limit × 2` hashes the first time a key set is
seen and usually one after that; a row that cannot be reconstructed always
pays the full search. Raise the limit (e.g. 5040 for seven keys) if your
events carry wider metadata and you can afford the time.

**Re-sealing legacy rows is not provided.** See the 0.14.0 CHANGELOG for why
and for what a safe version would need.

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

## Generators

| Generator | Purpose |
|-----------|---------|
| `standard_audit:install` | `audit_logs` migration + initializer (new installs) |
| `standard_audit:add_previous_checksum` | Adds `previous_checksum` (upgrading from < 0.8) |
| `standard_audit:add_anonymized_at` | Adds `anonymized_at` (upgrading from < 0.12) |
| `standard_audit:add_checksum_version` | Adds `checksum_version` (upgrading from < 0.14) — see "Checksum algorithm versions" |

The upgrade generators number their migration one second after the newest
migration already in `db/migrate` when that is later than now (0.13.0+), so the
new migration sorts after future-dated host migrations instead of before them.
Before 0.13.0 they stamped the current time. (`standard_audit:add_checksums`,
the 0.2 → 0.3 upgrade path, was removed in 0.13.0.)

## Rake Tasks

```bash
# Verify chain integrity (exits non-zero on failures)
rake standard_audit:verify
# ...accepting unreconstructable legacy rows created before a cutover (policy)
ACCEPT_LEGACY_UNVERIFIABLE_BEFORE=2026-09-26T00:00:00Z rake standard_audit:verify

# Record the parent digest each existing row was signed against
rake standard_audit:relink_checksums

# Delete logs older than N days
rake standard_audit:cleanup[180]
# ...or older than config.retention_days
rake standard_audit:cleanup

# Archive old logs to a JSON file before deleting (same days rules)
rake standard_audit:archive[90,audit_backup.json]

# Show statistics
rake standard_audit:stats

# GDPR: anonymize all logs for an actor
rake "standard_audit:anonymize_actor[gid://myapp/User/123]"

# GDPR: export all logs for an actor
rake "standard_audit:export_actor[gid://myapp/User/123,export.json]"
```

`cleanup` and `archive` take the window from the days argument, else
`config.retention_days`; if neither is set they abort (a nil `retention_days`
means keep forever, so there is no implicit 90-day default). Days must be a
positive integer — `0`, negatives and non-numeric values abort instead of
deleting everything.

`anonymize_actor` and `export_actor` take a GlobalID string and work even after
the user record has been deleted.

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

`jsonb` and MySQL `JSON` reorder object keys. Since 0.14.0 the checksum does
not depend on key order; rows written by earlier versions may — see
"Checksum algorithm versions".

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

### Records in metadata

An ActiveRecord object appearing anywhere in metadata is replaced, by default,
with a reference rather than a snapshot of the row:

```ruby
{ account: account }
# => { account: { "gid" => "gid://myapp/Account/1", "type" => "Account", "id" => "1" } }
```

This applies at any depth, inside Arrays, Hashes and `ActiveRecord::Relation`s,
on both write paths. It is on by default because key-based redaction cannot
reach the problem: a payload key like `account:` looks like exactly the kind of
key you want on an audit row, while the value serialises with
`password_digest`, `token_digest`, `lookup_hash` and anything else the table
happens to hold. Audit rows are append-only, so an unsafe default cannot be
walked back.

Records are dereferenced **after** `metadata_builder` (and `before_write`)
run, so a builder that needs real attributes still gets the record. Since
0.12.0 this holds on every write path, including direct `StandardAudit.record`
calls:

```ruby
config.metadata_builder = ->(metadata) {
  metadata.merge(account_email: metadata[:account]&.email)
}
```

`config.dereference_record_metadata = false` restores the pre-0.11.0 behaviour
of writing full attributes. Prefer `metadata_builder` over turning it off.

**Performance**: For high-volume applications, enable async processing and ensure your `audit_logs` table has appropriate indexes (the install generator adds them by default). Consider partitioning by `occurred_at` for very large tables.

**Retention**: Set `retention_days` in your configuration and run `rake standard_audit:cleanup` via a scheduled job (e.g., cron or SolidQueue recurring). Archive before deleting if you need long-term storage.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
