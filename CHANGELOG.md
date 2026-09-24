# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.13.1] - 2026-09-25

Fixes the checksum so it survives PostgreSQL `jsonb`
([fundbright/delivery-ops#689](https://github.com/fundbright/delivery-ops/issues/689)).
Through 0.13.0, the row digest hashed `metadata.to_json` in the order the
Ruby hash was built. `jsonb` stores keys in its own order (shortest first,
then bytewise). So any row whose metadata had more than one key failed
`verify_chain` with `digest_mismatch`, unless its keys happened to be
written in that order. In fundbright production that is 17,448 of 25,910
rows (67%). It, not concurrency, was the main cause behind
fundbright/delivery-ops#433; the 0.8.0 recovery search rescues 24 of those
rows. Every host on `jsonb` is affected: fundbright, sidekick, jumpdrive,
luminality and nutripod. The gem's suite runs on SQLite, which keeps JSON as
text in insertion order, so it never saw the bug.

### ⚠️ Deploy before 2026-10-01T00:00:00Z

The new checksum switches on **by the clock, not by deploy**. Rows whose
`created_at` is at or after `StandardAudit::CANONICAL_CHECKSUM_CUTOVER`
(**2026-10-01T00:00:00Z**) are signed with the canonical checksum and
verified strictly with it. **Every process that writes audit rows must run
0.13.1 before then.** A web worker or job runner still on an older gem after
the cutover writes legacy-hashed rows with post-cutover timestamps. Those
rows fail verification as `:digest_mismatch`, and the only honest fix
afterwards is to explain them.

If your rollout will slip, set `config.canonical_checksum_since` to a later
time **before 2026-10-01**, in a `configure(baseline: true)` block. Never move
it once the time has passed: verification recomputes the same decision from
each row's stored `created_at`, so moving it re-judges rows under the other
algorithm.

### Upgrade steps

1. Bump to 0.13.1 and deploy **before 2026-10-01T00:00:00Z** (or move
   `config.canonical_checksum_since`, as described above). **No migration or
   new column is needed.**
2. Regenerate Sorbet RBIs where the app uses Tapioca. This release adds
   `StandardAudit::Checksum` and new `verify_chain` keywords.
3. After the cutover, run `verify_chain` (or `rake standard_audit:verify`)
   and read the new counts; see "What `verify_chain` reports" below. Rows
   created after the cutover should all verify. Record the
   `legacy_unverifiable` count and alert if it ever grows.
4. **Decide the policy for legacy rows that can't be reconstructed.** This
   is a human decision (#689 options a to c). The gem reports these rows; it
   does not make the call.

**Requires Rails 8.1** (`activerecord`, `activejob`, `activesupport` `>= 8.1`,
was `>= 8.0`). Every consumer app runs 8.1; 8.0 was never exercised in CI.

### Changed

- **Canonical checksum for rows created at or after the cutover.** It is
  the SHA-256 of canonical JSON
  `{"fields": {…}, "previous_checksum": …, "v": 2}`:
  - JSON values (metadata, or any Hash/Array field) are round-tripped exactly
    as the column stores them.
  - Object keys are sorted bytewise at every depth.
  - Integral floats hash as integers, and times as UTC ISO 8601 with
    microseconds.
  - Strings are escaped at the byte level.
  - nil is distinct from `""`.

  Every input to the digest was audited. `CHECKSUM_FIELDS` is unchanged, and
  `metadata` is the only JSON field in the shipped schema. The parent is
  covered. The canonical form also closes a field-shifting ambiguity in the
  legacy form, where `|` inside a value could move content between adjacent
  fields with the same digest.
- **Rows created before the cutover keep the legacy digest byte for byte**
  (`StandardAudit::Checksum.legacy_digest`). They are written and verified
  exactly as before.
- The algorithm is chosen from `created_at` on every write path: `create`,
  the batched `insert_all!` path, and `backfill_checksums!`. Verification and
  `relink_checksums!` make the same choice. `created_at` is fixed before the
  checksum is computed, so the writer and the verifier read the same stored
  value. `created_at` is not itself hashed; see "Alert if it grows" below.
- `compute_checksum_value` (instance and class) picks the algorithm from
  `created_at`. `version:` forces one (`Checksum::LEGACY` / `CANONICAL`).
- **`verify_chain` returns `reordered:`, `legacy_unverifiable:` and
  `unverifiable:`**, and takes `key_order_search_limit:` (default 720) and
  `fail_on_legacy_unverifiable:` (default false). Existing keys and reasons
  are unchanged.
- `rake standard_audit:verify` prints the cutover, the new counts and a tally
  per reason. It takes `FAIL_ON_LEGACY_UNVERIFIABLE=1` and
  `KEY_ORDER_SEARCH_LIMIT=<n>`.

### What `verify_chain` reports

**Rows created at or after the cutover** are checked with the canonical
digest only, against the declared parent, else the preceding row, else the
recovery search. A mismatch is `:digest_mismatch`. These rows are never
classified as legacy. Chain linkage holds across the cutover: the first
canonical row's parent is the last legacy row's checksum.

**Rows created before the cutover** are first checked with the legacy digest
exactly as in 0.13.0: stored order, against the declared parent, else the
preceding row, else the recovery search. A row that still doesn't reproduce
goes through these steps:

1. **Key-order reconstruction.** The insertion order can't be read back,
   because `jsonb`'s order depends only on the key set. It can be searched,
   though: an ordering of the stored keys (at every depth) that reproduces the
   digest the row has held since it was written is a witness, in the same
   sense as the parent search. A row whose values were edited reproduces no
   ordering.
   - Such rows count in `reordered` and are valid.
   - The search is bounded by `key_order_search_limit` orderings per row.
   - Orders learned from earlier rows with the same keys are tried first, so
     most rows cost one hash.
   - Parents tried: the declared parent, or else the preceding row and "no
     parent".
2. **`:digest_mismatch`** if the search covered every ordering against the
   parent the row declares, or if the row has no JSON object with more than
   one key (key order can't be why it fails).
3. **`:missing_parent`** if the declared parent is gone.
4. Otherwise **`:legacy_key_order_unverifiable`**: the row has a multi-key
   object and every other check passed. It is listed in `unverifiable` and
   counted in `legacy_unverifiable`.

**`valid` semantics.** `valid` is still `failures.empty?`. A
`:legacy_key_order_unverifiable` row **does not make the chain invalid on its
own**, because it means "cannot be proven either way": an edited legacy row
looks exactly like one whose key order was lost. It is never silent. It is
reported separately with a count, and `fail_on_legacy_unverifiable: true`
turns these rows into failures.

**Alert if it grows.** After the cutover, no new legacy row can be written,
so under honest operation `legacy_unverifiable` never grows. Growth means a
pre-cutover row was edited, or a row's `created_at` was moved back across
the cutover.

How many fundbright rows reconstruction rescues depends on their key counts
and on whether they carry `previous_checksum`. That hasn't been measured on
production data yet.

### Added

- `StandardAudit::CANONICAL_CHECKSUM_CUTOVER` (frozen,
  `Time.utc(2026, 10, 1)`) and `config.canonical_checksum_since`, which
  defaults to it.
- `StandardAudit::Checksum` (`algorithm_for`, `digest`, `legacy_digest`,
  `canonical_digest`, `canonical_json`) and
  `StandardAudit::Checksum::KeyOrderSearch`.
- **A PostgreSQL CI leg** (`test (postgres)`: `postgres:16-alpine`, `jsonb`
  metadata) runs the full suite. The SQLite matrix stays. The dummy app uses
  `DATABASE_URL` when it is set. New specs cover:
  - both sides of the cutover, a row just before and just after it, the
    config override, and the batch and backfill paths;
  - linkage across the cutover;
  - the `jsonb` regression. On Postgres the specs also assert that the stored
    order really changed and that the legacy digest fails on it.

### Not included: re-sealing legacy rows

No tool re-signs legacy rows with the canonical digest. This is deliberate,
and a follow-up if you want one. Re-sealing replaces an attestation made at
write time with one made today. It needs an operator to attest to the rows
first, and it has to keep the chain intact, because each row's successor
hashed the row's *old* checksum as its parent. A safe version would need to:

1. keep the original checksum (for example in a `legacy_checksum` column) so
   the successor link can still be checked;
2. record who re-sealed which rows and when (a `resealed_at` stamp plus an
   audit event);
3. re-seal only rows classified `:legacy_key_order_unverifiable`, never a
   `:digest_mismatch`;
4. have `verify_chain` report re-sealed rows separately, so a re-seal never
   reads as original evidence.

That is a schema change plus a policy decision, so it is left for a separate
release. `backfill_checksums!` is still only for rows that never had a
checksum; don't use it for this.

## [0.13.0] - 2026-09-24

The Phase 4 release. It removes what 0.12 deprecated, the empty engine
routing, and the gaps the five app adoptions of 0.12 ran into.

### Removed (breaking)

- **`standard_audit:add_checksums` generator** (deprecated in 0.12.0). It was the 0.2 → 0.3 upgrade path. Every install since 0.3 creates `checksum`; hosts older than 0.8 run `standard_audit:add_previous_checksum`.
- **`isolate_namespace StandardAudit` and the empty `config/routes.rb`.** The engine has no routes, controllers or views, and no host mounts it. `AuditLog` sets its own `table_name`, so table naming is unchanged. Side effects: `StandardAudit::Engine.routes` no longer holds an (empty) isolated route set, and `StandardAudit.table_name_prefix` / `railtie_namespace` are no longer set by isolation. The gem uses neither.

### Added

- **`config.error_reporter = ->(error, context) { … }`**, the destination for every error the gem swallows: `record(raise: false)`, subscriber writes, raising `before_checksum` hooks, and `audit!` write failures under the default policy. nil (the default) keeps `Rails.error.report(error, handled: true, context:)`, so nothing changes unless you set it. Apps that don't forward `Rails.error` to their tracker (jumpdrive-web, nutripod-web) can report straight to Sentry instead of wrapping calls in their own rescue. A raising reporter is logged and ignored. `audit_write_error_handler` still takes precedence for `audit!`.
- **`entry[:via]` in `before_write`**: `:direct` (`record` without a block, `record_audit`, `audit!`), `:notification` (the ActiveSupport::Notifications subscriber, including `record` with a block), or `:rails_event`. A hook can now tell a direct write from a subscriber write. Not persisted. `StandardAudit::VIA` lists the values.
- **`hooks:` option on the `"a standard_audit baseline"` shared example**: an Integer (exact `before_checksum` hook count) or an Array of Symbol hook names. The mutation example clears the hooks before the reset, so it fails when a hook lives outside the baseline block.

### Fixed

- **Upgrade generators number the migration after the host's newest migration.** `add_anonymized_at`, `add_previous_checksum` and `install` stamped `Time.now`, which sorts before future-dated host migrations. They now use the later of now and one second after the newest migration in the target directory (a real timestamp, unlike ActiveRecord's `+1`, which can produce `…235960`).
- **README `before_write` example.** It showed a PII guard in `before_write` next to a masking `metadata_builder`. `before_write` runs after the builder, so the guard only ever saw masked values. The README now documents the order (resolvers → `metadata_builder` → `before_write` → dereference → redact → persist) and shows guard-then-mask inside `before_write`.

### Upgrade notes (0.12.x → 0.13.0)

Grepped `origin/main` of sidekick-web, jumpdrive-web (control-plane), fundbright-web, luminality-web and nutripod-web on 2026-09-24.

**Required host changes: none.** No app runs `add_checksums`, mounts `StandardAudit::Engine`, or uses its route helpers. Regenerate Sorbet RBIs (`bin/tapioca gem standard_audit`, `bin/tapioca dsl`) where the app uses Tapioca.

**Optional cleanups this release enables:**
- sidekick-web `spec/initializers/standard_audit_baseline_spec.rb:49-53` ("still carries the two classification hooks after a reset"): replace with `hooks: 2` on the `it_behaves_like` call.
- jumpdrive-web `control-plane/app/services/mcp/server.rb:98-104` (`audit_tool` rescue → `ErrorReporting.notify`): replace with `StandardAudit.record(..., raise: false)` plus a `config.error_reporter` that calls `ErrorReporting.notify`. Or keep it, since it also adds `component:` context.
- nutripod-web `app/controllers/concerns/audit_auth_failure.rb:92-96`: the rescue reports through `Rails.error` itself, so it can become `record(..., raise: false)` with `config.audit_error_context_key = :audit_event`, like the other apps. Add a `config.error_reporter` if nutripod-web does not forward `Rails.error` to Sentry.
- fundbright-web `AuditWritePolicy` (`before_write`) can use `entry[:via]` if its PII guard should skip gem-published subscriber payloads.
- Any `before_write` that iterates every `entry` key now also sees `:via`.

## [0.12.1] - 2026-09-24

### Upgrade steps

1. **If you installed the 0.12.0 `add_anonymized_at` migration, check your copy.** The 0.12.0 template put `return if column_exists?(:audit_logs, :anonymized_at)` inside `change`. That early return also runs on rollback, so `db:rollback` deleted the `schema_migrations` row and silently left the column in place. Replace the body with `add_column :audit_logs, :anonymized_at, :datetime, if_not_exists: true` (in `change`), or copy the new up/down template. Nothing to do if your copy already uses `if_not_exists:` (sidekick-web, jumpdrive-web) or if you never ran the generator.
2. If an error-tracker search or alert matches `before_checksum` hook failures on the `audit_event` context key, see Fixed.

### Fixed

- **The `add_anonymized_at` migration is reversible.** The template now uses explicit `up` / `down` with `add_column ..., if_not_exists: true` and `remove_column ..., if_exists: true`. It is still idempotent, and rollback now removes the column. A new generator spec runs the generated migration up, down and up.
- **`before_checksum` hook failures use `config.audit_error_context_key`.** The hook's `Rails.error.report` hard-coded `audit_event:` as its context key. Every other audit-error report site uses the configured key (default `:audit_action`). Apps that set `audit_error_context_key = :audit_event` see no change. Apps on the default now get `audit_action:` for hook failures too, matching every other audit error.

### Documentation

- `current_scope_resolver` is for scope derived from `Current`. Scope derived from the row (e.g. the target's organisation) belongs in a `before_checksum` or `before_write` hook. The README no longer describes sidekick-web's target-derived hook as a `Current` back-fill.
- New note: `before_write` / `before_checksum` run once per row, batched writes included. Memoize per-actor lookups (e.g. in a `CurrentAttributes` cache) to avoid an N+1 on a batch flush.
- `record(raise: false)` reports through `Rails.error`, so failures reach Sentry only if a `Rails.error` subscriber is registered (`sentry-rails` registers one).

## [0.12.0] - 2026-09-24

### Upgrade steps

1. Bump the gem and run `rails generate standard_audit:add_anonymized_at && rails db:migrate` (new nullable `audit_logs.anonymized_at`; idempotent, no table rewrite, strong_migrations-safe). Optional — without it everything works as in 0.11, and anonymized rows keep failing `verify_chain`.
2. StandardId apps: delete `config.current_actor_resolver = -> { Current.account }` and `config.current_session_id_resolver = -> { Current.session&.id }` — they are now the defaults.
3. If your `metadata_builder` must NOT run on direct `StandardAudit.record` / `audit!` writes, make it idempotent or move that logic (see Changed).
4. Optionally adopt `current_scope_resolver`, `before_write`, `raise: false` and `require "standard_audit/rspec"`'s `have_audited` / baseline shared example — each README section says which host code it replaces.

### Added

- **`config.before_write = ->(entry) { … }`** — runs on every write path (direct `record`, block form, `Auditable#record_audit`, `Operation#audit!`, both subscribers; sync, async and batched), after the Current resolvers and `metadata_builder` and before dereferencing/redaction. Mutate the entry in place; raising aborts the write (direct callers see the error; subscribers rescue and report it). Replaces host wrappers such as fundbright's `AuditWriting#record_audit!` and its `audit!` PII-guard/`surface` override.
- **`config.current_scope_resolver`** (default `nil`) — fallback audit scope when a write names none. Explicit `scope:` and `scope_extractor` results always win. Applied on every write path.
- **`StandardAudit.record(..., raise: false)`** — a failed write is logged, reported to `Rails.error` as handled, and returns nil. Replaces the `AuditAuthFailure` rescue-and-report wrappers.
- **`audit_logs.anonymized_at`** and the `standard_audit:add_anonymized_at` generator; the install migration now includes the column. `AuditLog#anonymized?` and `AuditLog.anonymization_column?`.
- **`verify_chain` result gains `redacted:`** — rows stamped `anonymized_at` are counted there instead of as `digest_mismatch` failures. Their stored checksum is kept, so the chain still links through them, and their declared parent is still checked for `missing_parent`. `rake standard_audit:verify` prints the count when nonzero.
- **RSpec support:** `have_audited("event").by(actor).on(target).within(scope).with_metadata(...).once` block matcher, and the `"a standard_audit baseline"` shared example. Loaded by `require "standard_audit/rspec"`, or individually from `standard_audit/rspec/matchers` and `standard_audit/rspec/baseline`.

### Changed

- **One write path.** Every entry point now ends in `StandardAudit.write_entry`. `StandardAudit::Subscriber` no longer re-implements the write, which has three visible effects:
  - **`metadata_builder` now runs on direct `StandardAudit.record` calls** (and therefore `audit!` / `record_audit`), not only on the subscriber paths. Builders that inject context (`engine_scope`) now reach direct writes, closing the gap fundbright-web's initializer documents. A builder that is not idempotent would now see operation metadata too — review before upgrading.
  - **Events handled by the ActiveSupport::Notifications subscriber inside `StandardAudit.batch` are now buffered** and flushed with the batch, like the `Rails.event` subscriber and direct calls already were. `before_checksum` hooks run for them (see Fixed).
  - Subscriber failures are logged as `[StandardAudit] Error creating audit log for <event>: …` and reported with the same context as 0.11.1.
- **Default resolvers match StandardId.** `current_actor_resolver` tries `Current.account`, then `Current.user`; `current_session_id_resolver` tries `Current.session&.id`, then `Current.session_id`. Each is `respond_to?`-guarded, so `Current.user` apps are unaffected. The README's zero-config claim for StandardId is now true.
- `Rails.event` reserved metadata (`_tags`, `_source`) is still merged after `metadata_builder`, so builders never see it.

### Fixed

- **`before_checksum` hooks now run on batched writes.** `StandardAudit.batch` flushes with `insert_all!`, which never built a model, so hooks silently skipped every batched row. The flush now runs each buffered row through the hooks (per-hook isolation included) before checksumming, so batched rows get the same derived columns as `save!` and still verify.

### Deprecated

- **`standard_audit:add_checksums` generator** — the 0.2 → 0.3 upgrade path. It still works but warns; removal is planned.

## [0.11.1] - 2026-09-24

### Fixed

- **`rake standard_audit:anonymize_actor[gid]` and `standard_audit:export_actor[gid]` no longer raise `NoMethodError`.** The tasks passed the GlobalID string straight into `AuditLog.anonymize_actor!` / `export_for_actor`, which called `to_global_id` on it. Both methods now accept a record, a `GlobalID`, or a GlobalID string. A string is parsed, not located, so erasure works after the subject's row has been deleted; an invalid string raises `ArgumentError`. What gets anonymized is unchanged.
- **`rake standard_audit:cleanup` no longer deletes logs older than 90 days when `retention_days` is nil.** nil means keep forever, but the task fell back to a hard-coded 90. `cleanup` and `archive` (which always defaulted to 90) now take the days argument, else `config.retention_days`, else abort with a message saying how to set one.
- **`cleanup`/`archive` reject a days value that is not a positive integer.** `cleanup[abc]` used to become `0` days, i.e. delete every row. `0`, negatives and non-numeric values now abort. `StandardAudit::CleanupJob` is unchanged.
- **`StandardAudit::Subscriber` and `StandardAudit::EventSubscriber` report swallowed errors to `Rails.error`.** A failed audit write was only logged, so it never reached error tracking. It is now also reported with `handled: true` and context `{ <config.audit_error_context_key> => event_name, subscriber: <class name> }`. The log line is kept.

## [0.11.0] - 2026-07-31

### Security

- **ActiveRecord objects in audit metadata are no longer written with all of their attributes.** Any record found in metadata — at any depth, and inside Arrays, Hashes and `ActiveRecord::Relation`s — is now replaced with a reference: `{ "gid" => "gid://app/Account/1", "type" => "Account", "id" => "1" }`. Applies to both write paths (`ActiveSupport::Notifications` and `StandardAudit.record`).

  `standard_id` publishes live records under payload keys like `account:`, `current_account:`, `session:` and `code_challenge:`, and `Subscriber#extract_metadata` excluded only `actor`/`target`/`scope`/`request_id`/`ip_address`/`user_agent`/`session_id` — every other key was written whole. Confirmed present in real `audit_logs` rows: `account.password_digest`, `account.password_reset_token_digest`, `session.token_digest`, `session.lookup_hash`, `code_challenge.code`.

  All three existing defences missed, each for a different reason: `sensitive_keys` matches key names exactly and the secrets are attributes *underneath* `account:`; `filter_nested_metadata` is off by default so the filter never descended to them; and `account:` does not look sensitive at the top level. This is not a redaction bug — key-based redaction is the wrong tool for a value that is an entire database row — so the value is replaced by type, before any key filtering runs.

  **This fix stops the bleeding; it does not clean up.** `audit_logs` is append-only by design (`before_update` and `before_destroy` raise `ReadOnlyRecord`), so every row already written keeps its digests, for the whole of a retention window that is intentionally long. Upgrading changes only what is written from now on. Assessing and remediating existing rows is a separate, host-side exercise.

  `sensitive_keys` semantics are untouched: still exact-match, still no substring mode. See rarebit-one/rarebit-ops#296.

### Added

- **`config.dereference_record_metadata`** (default `true`) — the escape hatch for the above. It defaults to the SAFE behaviour, unlike `filter_nested_metadata`, because the values it catches are ones no host asked to record: they arrive as a side effect of a payload carrying `account:` or `session:`, and an append-only row cannot be walked back. Set it to `false` only if an app genuinely depends on record attributes in metadata and has satisfied itself no secret-bearing column can reach a row.

### Changed

- **Consumer-visible beyond the secrets disappearing:** any metadata key that used to hold a record's attribute hash now holds a three-key reference, so dashboards, reports or queries reading e.g. `metadata->'account'->>'email'` will read `NULL` on new rows (old rows are unchanged, which makes the change look like a data gap rather than a schema change). Recover the specific fields you need with `metadata_builder`, which runs BEFORE dereferencing and still receives the record: `->(metadata) { metadata.merge(account_email: metadata[:account]&.email) }`. `actor`/`target`/`scope` are unaffected — they were already stored as GlobalIDs.

## [0.10.0] - 2026-07-31

### Added

- **`config.audit_error_context_key`** (default `:audit_action`) — renames the `Rails.error.report` context key naming the audit action, without needing a whole handler. Two apps had overridden `audit_write_error_handler` for nothing but this: both tag every OTHER audit-error report site with `audit_event:` (four sites in one, twelve across ten files in the other), so adopting the gem name left the operations layer as the only place forking the convention. A handler written to rename one key also silently opts out of every future improvement to the built-in reporter.

### Changed

- **The built-in reporter no longer fires when `raise_on_audit_write_error` re-raises.** The caller receives the error and owns it, so reporting as well produced two events for one failure in every host that both sets the flag and reports on what it catches — which is most hosts that set it at all, since the flag exists for hosts treating an unaudited write as a failure worth handling. Two of the five apps hit this independently and each wrote a log-only handler to work around it. A host that does NOT catch the error still gets a report, via its framework unhandled-error path. An explicitly configured `audit_write_error_handler` is unaffected and still runs under either policy — only the built-in reporter steps aside.

### Fixed

- **The write-site scan no longer reads comments as calls.** An operation declaring `audit_none!` that explained itself in prose naming `audit!` was flagged by `unexpected_write_sites` — a false failure, which hosts worked around by backticking the token in their own comments. Source is now lexed with `Ripper` and comment tokens dropped before scanning; a file that cannot be lexed falls back to raw source (the old behaviour). Lexing rather than stripping `#` to end-of-line, because the naive form eats `"#{interpolation}"` and `%w[#]` and would trade a false failure for a false pass.
- **Corrected a docstring that was wrong for half its own surface.** It claimed the source-scanning predicates "err towards a false pass rather than a false failure". That held only for `missing_write_sites`; in the `unexpected_write_sites` direction the same match produced a false failure. Worse than the bug itself, since it told anyone hitting the failure not to suspect the scanner.

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
