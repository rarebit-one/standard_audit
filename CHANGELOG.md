# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-07-31

### Added

- **`StandardAudit::Operation` — the operation-audit DSL, extracted from five independent copies.** Every consumer app had written the same contract by hand: `audits "x.y"` / `audit_none!` class declarations, a private `audit!(action, **attrs)` as the single write path, and a `verify_audit_declared!` guard that raises on declaration↔write drift in local environments and writes silently in production. The surface is unchanged from those copies, so operation files do not move — adopting apps swap one `include` line and delete their concern. (`rarebit-one/rarebit-ops#279`)
  - It is a **module, never a base class**. The five host `ApplicationOperation`s range 61–303 lines and diverge deliberately (one refuses a `Result`/`execute` lifecycle; one app has no shared base at all), so the module contributes the audit contract and nothing else.
  - **Both adoption shapes work with no configuration**: a shared base that includes it once, whose subclasses are the real operations, and standalone leaves that each include it directly. The unifier is that a class declaring nothing *and* having subclasses is treated as a base and excluded — so a shared base auto-excludes, while every leaf is retained. A class that did declare is never excluded that way.
  - `audit_abstract!` for an intermediate class the automatic rule can't see (typically one with no subclasses yet).
- **`config.audit_catalogue`** — the host's action vocabulary, as a **callable** (`-> { AuditCatalogue::ACTIONS }`); referencing an autoloadable constant eagerly from an initializer breaks Zeitwerk reloading. A plain Array is accepted for a frozen literal. `nil` (the default) skips the membership check, so the DSL is adoptable before an app has a catalogue. **Membership is the only rule applied** — no dot-count, case, prefix, or namespace validation, because an action may legitimately carry a notification-bus namespace verbatim and normalising it would orphan historical rows.
- **`config.raise_on_audit_write_error`** (default `false`) and **`config.audit_write_error_handler`**. Four of the five apps report-and-swallow a failed audit write; one deliberately does not rescue, because for it an unaudited state change is itself a compliance failure. A swallow-only module would have silently downgraded that posture. `StandardAudit::Operation::DeclarationError` is never governed by either — it always re-raises, ahead of any generic rescue.
- **`config.verify_audit_declarations`** (callable or boolean, default: local environments only) — gates the dev/test guard.
- **Meta-spec logic as plain Ruby predicates** on `StandardAudit::Operation::Audit`: `.operations(source:)`, `.undeclared`, `.unknown_actions`, `.orphan_actions(within:)`, `.missing_write_sites`, `.unexpected_write_sites`, `.duplicate_catalogue_entries`, `.declared_actions`. Each takes an explicit `operations:` list, so hosts can write bespoke assertions.
- **`standard_audit/rspec/operation`** — a thin RSpec shared-example layer over those predicates, with no logic of its own. It carries a **`minimum:` registry floor**, the one example that catches "someone stopped including the module" or "eager loading stopped reaching the operations"; without it every other example passes vacuously against an empty set. Also `expected:`, `source:` scoping, and `orphans_within:` for hosts whose catalogue covers writers outside `app/operations/`.

Everything is additive and nothing includes the module by default — existing hosts upgrade with no code change.

## [0.8.0] - 2026-07-30

### Added

- **`previous_checksum` — every row now records the row it was appended to.** New nullable column; run `rails generate standard_audit:add_previous_checksum && rails db:migrate` to add it. The install migration includes it for new hosts, along with a composite `(created_at, id)` index for the verification walk.
- **`rake standard_audit:relink_checksums` / `AuditLog.relink_checksums!`** — records, for every row that has no `previous_checksum`, the parent digest it was *actually* signed against, recovering it by search where a concurrent append forked the log. It **never rewrites a `checksum`**: a parent is written only when it reproduces the digest the row has held since it was written, so it adds no attestation the rows did not already carry. Rows it cannot resolve are counted as `unresolved`, left untouched, and keep failing verification — which is the point. This is the repair path for a log broken by the defect below; `backfill_checksums!` is **not** (it re-signs rows from their current contents, so a green result attests only that a script ran).
- `AuditLog.chain_tip_checksum` and `AuditLog.chain_parent_column?`.

### Fixed

- **The chained checksum was not concurrency-safe: `verify_chain` failed for 3,762 of 5,577 rows (67%) on one production log, continuously, while every row was untampered.** `compute_checksum` reads the chain tip with an unsynchronised query from `before_create`. Two transactions cannot see each other's uncommitted rows, so both sign against the same predecessor and the sequence forks; verification, which assumed a strict line, reported all but one of them as tampering. Any host with concurrent audit writes — two Puma threads, a web request and a job — has the same broken log. (`fundbright/delivery-ops#433`)

  **The log is now treated as a DAG rather than a strict line, and each row records its parent.** A row is verified against the exact digest it signed, whether or not that is its predecessor in the walk, so a fork is verifiable instead of fatal. The tip read stays unlocked deliberately: forcing a strict line means holding a lock until the *enclosing business transaction* commits — a row is invisible to other writers until then, so releasing earlier reopens the race — which would serialise every audited request across the estate behind one mutex, on the hot path of every request. `previous_checksum` needs no protection of its own; it is an input to the row's own digest, so editing it invalidates the row.

  What this deliberately stops claiming: a single total order, and detection of an *inserted* row. A concurrent append and an inserted row are indistinguishable, so a design that tolerates the first cannot detect the second. The strict-line reading did not detect insertions either — it reported every concurrent append as tampering, which on the measured log meant 67% red and any real signal lost in it.

  **Rows written before this version verify unchanged, with no migration.** With no `previous_checksum`, verification falls back to the preceding row in the walk and then searches back through the last `recovery_window` (default 256) digests for the one that reproduces the row's checksum — recovering the true parent of a forked row without re-signing anything, and reporting how many needed it in the new `recovered:` count. Tamper detection is not weakened: a row whose fields were altered reproduces no candidate's digest. `verify_chain(strict: true)` skips the search and reports every fork as a failure. A host that never runs the migration keeps working on this path indefinitely.

- **`verify_chain` never noticed a row being removed from the middle of the log.** Failures now carry `reason:` — `:digest_mismatch`, or `:missing_parent` when the row a record was appended to is no longer present. Retention pruning does not trip it: if the walk opens on a row whose parent is already gone, that parent digest is exempt wherever else it appears — a pruned row can have several children, which is what a concurrent append leaves behind. A removal from the *middle* is still reported. Every row is exempt under `scope:`, because the log is global and a scoped row's parent usually belongs to another scope.

- **`verify_chain` did not walk the order it documents, and neither did `backfill_checksums!`.** Both claimed a `(created_at, id)` walk and both used `in_batches`, which paginates by **primary key** range and applies the sort only *within* each batch — so the global sequence was a concatenation of id-ranges, each internally time-sorted. Both now walk with a keyset cursor ordered by `(created_at, id)`, which is the documented order and still loads only `batch_size` rows at a time.

  With the UUIDv7 ids `assign_uuid` generates, id order usually coincides with insertion order, which is why this stayed latent — but it is wrong for any host that assigns ids differently, backfills rows with an explicit `created_at`, or has clock skew between writers. It matters more than a latent ordering bug normally would: the chain is an *ordering* claim, so a verifier that walks a different order than the one it documents cannot be trusted to prove or disprove anything about chain integrity, including the concurrent-append defect above. `backfill_checksums!` had the same defect, and there it silently *writes* the wrong chain rather than misreading one.

## [0.7.0] - 2026-07-30

### Added

- **Batch actor/target/scope preloading.** `AuditLog#actor` / `#target` / `#scope` resolved their GlobalID one row at a time, so every audit list N+1'd. Two consuming apps had already fixed this locally, both by reaching into private ivars (`instance_variable_set(:@preloaded_actor, …)`) because the gem exposed no setter. The gem now owns it:
  - `AuditLog.preload_references(logs, refs: %i[actor target], only: [...], includes: {...})` resolves a page in one query per distinct stored `*_type`, built on `GlobalID::Locator.locate_many` with `ignore_missing: true`.
  - `preloaded_actor=` / `preloaded_target=` / `preloaded_scope=` public writers, plus `actor_preloaded?` predicates.
  - The memo is a Hash consulted with `key?`, so *preloaded-but-deleted* memoizes `nil` and reads back without a query — distinct from *not preloaded*. `actor=` / `target=` / `scope=` populate the memo (they already hold the record); `reload` clears it.
  - `only:` is matched against the **stored type string by class name**. `GlobalID::Locator`'s own `:only` is evaluated as `gid.model_class <= klass`, which constantizes the historical type string *before* deciding whether it was permitted — so a renamed or deleted class raises `NameError` rather than being denied. Consequence: `only:` does not expand to subclasses or modules; list every concrete class. A non-whitelisted reference memoizes `nil`.
  - `includes:` is treated as a per-type map when every key is a String or Class (`{ "Order" => [:user] }`), and as a uniform Active Record includes spec otherwise (so `{ account: :identifiers }` still works as you'd expect).
  - A type string that no longer constantizes — or a blank `*_type` on a row that still carries a `*_gid` — is left *unmemoized*, so the per-row reader behaves exactly as it did before preloading was attempted. Preloading can never turn a resolvable reference into a permanent `nil`.
- `AuditLog#actor_model_id` / `#target_model_id` / `#scope_model_id` (and `AuditLog.reference_model_id(gid)`) — the model id extracted straight from the gid string, a helper three separate consumer call sites had hand-rolled. Deliberately **not** `GlobalID.parse(gid)&.model_id`: audit rows are historical and append-only, so a gid whose app segment differs from the current `GlobalID.app` is a real row that must still yield its id. Mirrors `URI::GID`'s own decoding (drops `?params`, `CGI.unescape`s each segment, returns an Array for a composite primary key) while ignoring the app name, so it agrees with `GlobalID#model_id` wherever that works and keeps working where it doesn't.


- **`config.before_checksum`** — registers a hook that runs on `before_create` **between `assign_uuid` and `compute_checksum`**. Definition order is execution order, so a hook may set a `CHECKSUM_FIELDS` member (back-fill `scope`, derive a column, rewrite `metadata`) and the row still passes `AuditLog.verify_chain`. Hosts previously had to register their own `before_create ..., prepend: true` to beat the gem's checksum callback — fragile ordering knowledge no host should need.
  ```ruby
  config.before_checksum { |log| log.scope = MyApp.derive_scope(log) }
  config.before_checksum :backfill_scope   # an AuditLog instance method
  ```
  Hooks accumulate and run in registration order. **Each is rescued individually** — a failing hook logs (and reports to `Rails.error`), is **rolled back to the attributes it started from**, and is skipped; the remaining hooks still run and the audit write never fails. The rollback is what makes "skipped" true: without it, a hook that assigns `scope_gid` and then fails a later lookup would leave a half-applied row for the following callbacks to checksum and persist. If a row is created with an explicit `checksum`, hooks still run (most derived columns are not checksummed) but the supplied digest is dropped and re-derived when a hook changed a `CHECKSUM_FIELDS` member. Hooks do not run on the batched `insert_all!` path, which never instantiates a model.
- **`StandardAudit.configure(baseline: true)`** — remembers the block so `reset_configuration!` replays it onto the fresh Configuration. **Required companion to the `before_checksum` hooks, not optional.** The config object holds *behaviour*, not just data, so a suite that installs `standard_audit/rspec` (whose per-example `reset_configuration!` restores gem defaults) would silently lose its write-time hooks after the first example — and the specs that would have caught it pass vacuously. The install template now uses `configure(baseline: true)`, and the `lib/standard_audit/rspec.rb` docstring no longer instructs hosts to re-apply configuration by hand. `reset_configuration!(replay_baseline: false)`, `clear_baseline_configuration!` and `baseline_configured?` round it out. A plain `configure` is unchanged and registers nothing.


- **`config.sensitive_key_patterns`** (Array of Regexp, always applied, default `[]`) — the supported way to catch a family of keys. Stripe's `client_secret` slipping past the exact-match `:secret` is solved by `/secret/i`.

  **There is deliberately no substring matching mode**, and one should not be added. Against the current default key list, substring matching strips real audit content across the estate: `input_tokens` / `output_tokens` (live LLM cost accounting in luminality and sidekick), `token_digest` (rendered in luminality's staff audit UI), `password_reset_sent_at`, `authorization_endpoint`, even `onepassword`. Audit rows are append-only, so it cannot be undone — the content is simply never written from then on. Patterns are opt-in, per-app, and checkable in advance.
- **`config.sensitive_key_exceptions`** (Array of exact names or Regexps, default `[]`) — never redacted, even when `sensitive_keys` or a pattern matches. Lets an app adopt `[/token/i]` while keeping `input_tokens` / `output_tokens`.
- **`rake standard_audit:sensitive_keys:dry_run`** — read-only. Reports, per metadata key, what a candidate rule *would* have stripped from the rows you already have, what it would keep, and any nested matches that survive because `filter_nested_metadata` is off. Turns "is this rule safe for my app?" into a command rather than a guess, which matters precisely because the rows are append-only.
  ```bash
  bin/rails standard_audit:sensitive_keys:dry_run                 # current config
  bin/rails "standard_audit:sensitive_keys:dry_run[secret]"       # candidate pattern
  NESTED=1 bin/rails "standard_audit:sensitive_keys:dry_run[secret|token]"
  ```
  Backed by `StandardAudit::SensitiveKeysDryRun.call(...)`, which extracts keys **in Ruby** rather than with `jsonb_object_keys` so it stays backend-neutral.
- `StandardAudit::MetadataFilter` — `MetadataFilter.call(metadata, config:)` filters metadata; `MetadataFilter.new.filter?(key)` answers the same question for a single key without writing a row. Matching stays **exact on the key name** (string/symbol insensitive), unchanged from 0.6.0. Anything hash-like is filtered (so `ActionController::Parameters` is redacted, not waved through because it isn't a `Hash`); `nil` passes; anything else raises `MetadataFilter::UnfilterableMetadataError` rather than writing unfiltered content to an append-only row.

### Fixed

- **Nested metadata was never redacted on either write path.** `metadata: { stripe: { client_secret: … } }` was written intact even under exact matching — a larger real leak than the top-level case. Opt in with `config.filter_nested_metadata = true` (default `false`, so 0.6.0 behaviour is preserved); redaction then descends into nested Hashes and Hashes inside Arrays. `RESERVED_METADATA_KEYS` (`_tags`, `_source`) are preserved *and their subtree is never descended into, at every depth* — they are gem-owned, and `event_subscriber.rb` sets them after building metadata.
- **The two write paths applied different sensitive-key filters.** `StandardAudit.record` and `StandardAudit::Subscriber#extract_metadata` each carried an independent copy of the redaction logic, and they had already diverged: the subscriber copy did not subtract `RESERVED_METADATA_KEYS`, so an app that added `:_tags` or `:_source` to `sensitive_keys` had the reserved key preserved on the `record` path and stripped on the `ActiveSupport::Notifications` path. Both now call the single `StandardAudit::MetadataFilter`, and the divergence is resolved in favour of `record`'s behaviour — reserved keys can never be filtered on either path. Parity is driven from one shared example (`spec/support/shared_examples/metadata_filtering.rb`), so a future divergence fails the suite rather than shipping.

### Notes

- `StandardAudit.batch { ... }` flushes via `insert_all!` and never instantiates a model, so none of the above runs on the batched write path — the memo is a no-op there by construction.
- Minor behaviour change on a single instance: `log.actor = user; user.destroy!; log.actor` now returns the (destroyed) in-memory record instead of `nil`, because the writer memoizes. Reading the row fresh (or calling `reload`) is unchanged and still returns `nil`. This matches how Active Record association writers behave.

## [0.6.0] - 2026-06-24

### Added

- `config.retention_days` now defaults from the `STANDARD_AUDIT_RETENTION_DAYS` environment variable, so a deployment can opt into a retention window without a code change. Unset/blank/zero/negative/non-numeric resolves to `nil` (infinite retention — the compliance-safe default that never auto-deletes). Host apps can still override `config.retention_days` in their initializer.
- `StandardAudit::Checks::Retention` — a StandardHealth-compatible (duck-typed, no hard dependency) readiness check that flags unbounded retention on **production** deployments. Register it non-critical in `config/initializers/standard_health.rb`:
  ```ruby
  c.register_check :audit_retention, StandardAudit::Checks::Retention, critical: false
  ```
  When `APP_ENVIRONMENT == "production"` (falling back to `Rails.env.production?` so staging is not flagged) and `retention_days` is nil, it returns `:warn`, rolling `GET /health/ready` to `:degraded` — still HTTP 200, so it surfaces the advisory without failing the probe or blocking a deploy.

## [0.5.0] - 2026-04-29

### Changed

- CI and release workflows migrated to the shared `rarebit-one/.github` reusable workflows (`reusable-gem-ci.yml@v1`, `reusable-gem-release.yml@v1`); `.github/workflows/ci.yml` and `release.yml` are now thin shims.
- The `standard_audit:install` generator is now idempotent. Re-running it skips the migration when a `*_create_audit_logs.rb` file already exists in `db/migrate/`, and skips the initializer when `config/initializers/standard_audit.rb` already exists. New flags: `--skip-migration`, `--skip-initializer`, and `--force` (overwrite the existing initializer; defaults to skip without an interactive prompt).

### Removed

- **BREAKING:** Removed `Configuration#use_preset` and the `lib/standard_audit/presets/` directory. The preset pattern (`config.use_preset(:standard_id)`) created a direct dependency from `standard_audit` on a specific publisher gem, which inverted the intended dependency direction — `standard_audit` should be a generic event consumer with no knowledge of any particular publisher. Host apps should subscribe to event patterns directly:
  ```ruby
  StandardAudit.configure do |c|
    c.subscribe_to "standard_id.authentication.*"
    c.subscribe_to "standard_id.session.created"
    c.subscribe_to "standard_id.session.revoked"
    c.subscribe_to "standard_id.session.expired"
    c.subscribe_to "standard_id.account.*"
  end
  ```
  Each publisher gem documents its event namespace.
- **BREAKING:** Dropped support for Ruby < 4.0. `required_ruby_version` is now `>= 4.0`. Hosts must upgrade to Ruby 4.0+ before bundling this version. CI tests all four published 4.0.x patches.
- **BREAKING:** Dropped support for Rails < 8.0. `activerecord`, `activejob`, and `activesupport` constraints are now `>= 8.0` (was `>= 7.1`). Hosts on Rails 7.x must upgrade to Rails 8.0+ before bundling this version. Aligns with the org-wide policy of supporting Rails 8 and up.

## [0.4.0] - 2026-04-19

### Added

- Rails 8.1+ structured event reporter (`Rails.event`) integration. A new `StandardAudit::EventSubscriber` is registered automatically when `Rails.event` is available, so `Rails.event.notify("myapp.orders.created", actor: user, target: order)` persists an `AuditLog` the same way an `ActiveSupport::Notifications.instrument` call does. Event name is matched against the existing `subscribe_to` patterns (supports `*`, `**`, and `Regexp`). `Rails.event.set_context(...)` values take precedence over the `Current.*` resolvers for `request_id`, `ip_address`, `user_agent`, and `session_id`. `Rails.event.tagged(...)` and `source_location` are captured under the reserved metadata keys `_tags` and `_source`.

## [0.3.0] - 2026-03-31

### Added

- Tamper detection via chained SHA-256 checksums — each record's `checksum` column hashes its content plus the previous record's checksum
- `AuditLog.verify_chain` to walk the chain and detect modified records
- `AuditLog.backfill_checksums!` to retroactively checksum pre-existing records
- Rake tasks: `standard_audit:verify` (exits non-zero on failure) and `standard_audit:backfill_checksums`
- Upgrade generator: `rails g standard_audit:add_checksums` adds the checksum column and created_at index

### Changed

- Primary keys now use UUIDv7 (time-ordered) instead of UUIDv4 for deterministic chain ordering
- Batch inserts (`StandardAudit.batch`) now compute chained checksums

### Upgrade

Run the upgrade generator to add the checksum column:

```bash
rails generate standard_audit:add_checksums
rails db:migrate
```

Optionally backfill checksums for existing records:

```bash
rake standard_audit:backfill_checksums
```

## [0.2.0] - 2026-03-25

### Added

- Batch insert mode via `StandardAudit.batch { }` for high-volume audit logging
- `StandardAudit::CleanupJob` for automated retention enforcement
- `config.use_preset(:standard_id)` to subscribe to StandardId auth events in one call
- GIN index on metadata JSONB column in install generator (PostgreSQL)
- CI-driven gem publishing via GitHub Actions trusted publisher

### Changed

- Migration template uses `jsonb` instead of `json` for metadata column
- Expanded default `sensitive_keys` to include `api_key`, `access_token`, `refresh_token`, `private_key`, `certificate_chain`, `ssn`, `credit_card`, `authorization`

### Breaking Changes

- AuditLog records are now immutable — `update`/`destroy` raises `ActiveRecord::ReadOnlyRecord`. Use `update_columns` for privileged operations like GDPR anonymization. `delete`/`delete_all` still work for bulk cleanup.
- Removed `auto_cleanup` config attribute. Schedule `StandardAudit::CleanupJob` directly instead.

## [0.1.0] - 2026-03-03

### Added

- Core audit log model with UUID primary keys and GlobalID-based polymorphic references
- Convenience API: `StandardAudit.record` with sync, async, and block forms
- ActiveSupport::Notifications subscriber for automatic event capture
- Configurable Current attribute resolvers for request context
- Multi-tenancy support via scope column
- 20+ composable query scopes (by actor, target, scope, event type, time, request context)
- Async processing via ActiveJob with configurable queue
- Sensitive key filtering for metadata
- GDPR compliance: `anonymize_actor!` (right to erasure) and `export_for_actor` (right to access)
- Model concerns: `Auditable` for actors/targets, `AuditScope` for tenant models
- Install generator with migration and initializer templates
- Rake tasks for cleanup, archival, statistics, and GDPR operations
