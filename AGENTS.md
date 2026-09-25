# AGENTS.md - AI Agent Guide for StandardAudit

StandardAudit is a Rails engine providing database-backed audit logging via
`Rails.event` (Rails 8.1+) and `ActiveSupport::Notifications`. Audit records
land in a single `audit_logs` table with `GlobalID`-based polymorphic actor /
target / scope columns, optional async dispatch via ActiveJob, a tamper-evident
checksum chain, and GDPR-friendly anonymize / export helpers.

## Public API

- `lib/standard_audit.rb`: `StandardAudit.record`, `.batch`, `.configure`.
- `app/models/standard_audit/audit_log.rb`: the append-only model, its scopes,
  the checksum chain, `preload_references`, and the GDPR helpers.
- `lib/standard_audit/operation.rb`: the operation audit DSL
  (`audits` / `audit_none!` / `audit!`); predicates in `lib/standard_audit/operation/audit.rb`.
- `lib/standard_audit/rspec.rb` and `lib/standard_audit/rspec/operation.rb`: the
  host-facing RSpec plugin and shared examples.
- `lib/generators/standard_audit/install/`: `rails g standard_audit:install`.

## Commands

```bash
bundle exec rspec                 # dummy app, in-memory SQLite, no db:setup step
bundle exec rubocop -A
bundle exec brakeman --no-pager
bundle exec bundler-audit --update
DATABASE_URL=postgres://user:pass@host:port/standard_audit_test bundle exec rspec
```

CI also runs the suite on PostgreSQL (`test (postgres)`): `jsonb` reorders keys.
The helper DROPS and recreates the `public` schema of that database on boot
(it refuses a database whose name lacks `test`), so point it at a throwaway.

## Invariants

- **Never change a released digest algorithm**, since stored rows must keep reproducing. Any new
  write path must fix `created_at` before it computes the checksum.
- **Do not reorder the three `before_create` lines** in `app/models/standard_audit/audit_log.rb`:
  `assign_uuid`, then the `before_checksum` hooks, then `compute_checksum`, so a hook
  may set a `CHECKSUM_FIELDS` member and the row must still pass `verify_chain`.
- `StandardAudit.batch` writes with `insert_all!`, which bypasses Active Record:
  no callbacks, no `before_checksum` hooks, no preload memo. Logic that must
  apply to batched rows sets the buffered attrs, not a model hook.
- **Any new Configuration field must be in the `attr_accessor` list AND
  defaulted in `initialize`**, or the rspec plugin's per-example reset leaves
  it nil.
- Host initializers use `StandardAudit.configure(baseline: true)`, so that
  `reset_configuration!` replays it. Without it, a suite on `standard_audit/rspec`
  loses its `before_checksum` hooks after the first example, and the specs that
  would notice pass vacuously.
- `StandardAudit::Operation` **is a module, never a base class. Never add a
  lifecycle to it.** The five host `ApplicationOperation` bases diverge deliberately.
- `@audit_spec` is not inherited: a leaf inheriting its parent's declaration
  would pass the meta-spec while writing nothing.
- The event catalogue is a host-declared callable (a constant breaks Zeitwerk
  reloading). Membership is the only validation, because normalising names would
  orphan historical rows. `DeclarationError` always re-raises.
- **One filter, two write paths.** `StandardAudit::MetadataFilter` is the only
  redaction implementation; do not reintroduce a local `sensitive_keys` reject.
  Parity is pinned by `spec/support/shared_examples/metadata_filtering.rb`. The
  filter fails closed.
- **There is no substring matching mode, and do not add one.** Audit rows are
  append-only, so over-redaction (`input_tokens`, `token_digest`, ...) cannot be
  undone. `sensitive_key_patterns` is the opt-in tool.
- The gem knows no publisher gem's event names: the dependency direction stays
  one-way, and hosts `subscribe_to` whatever they audit.

## Footguns

- Nested metadata is unfiltered unless `config.filter_nested_metadata` is true.
- The default `:authorization` sensitive key also strips policy-decision keys;
  rename them (e.g. `:authorization_policy`).
- Dry-run any redaction rule against real rows first:
  `rake "standard_audit:sensitive_keys:dry_run[secret]"` (`NESTED=1` for nested).
- `preload_references(only:)` matches stored class names exactly, with no
  subclass expansion, so list every concrete class.
- The checksum chain is best-effort under concurrent writers; use a DB advisory
  lock if you need serialisable integrity.
- Pre-push lefthook (`lefthook.yml`) runs rubocop, brakeman and rspec;
  bundler-audit runs only in CI.

## Workspace rules

- **Worktrees only.** Edit in `.worktrees/<name>/`, never in the main checkout.
  `.agents/hooks.toml` registers `enforce-worktree` (Edit/Write/NotebookEdit) and
  `enforce-worktree-bash` (Bash writes into the main checkout: `sed -i`, `tee`,
  redirects, `cp`/`mv`, `git apply`, `rsync`); scripts are in `.agents/hooks/`.
  There are no opt-outs; CI checkouts are the only exception.

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git fetch origin "$DEFAULT_BRANCH"
git worktree add .worktrees/<name> -b <branch-name> "origin/$DEFAULT_BRANCH"
```

- **Signed commits only.** `enforce-signed-commits` adds `-S` to `git commit`; if
  signing fails, stop and report it, and never pass `--no-gpg-sign`.

See the `/worktree` and `/start` skills for full conventions and flags.

## Where to look

- `docs/agents/architecture.md`: layout, every pattern above in full, the table, key files.
- `docs/agents/security.md`: redaction rules, GDPR, append-only, the default key list.
- `docs/agents/testing.md`: the full command reference and spec conventions.
- `docs/agents/workflows.md`: recording an event, async processing.
- `README.md`: host-facing installation and configuration.

## Consumers

`standard_audit` is consumed by these apps in the rarebit-one workspace:

- `fundbright-web`
- `luminality-web`
- `nutripod-web`
- `sidekick-web`
- `jumpdrive-web` (the control-plane app, formerly `workspace-os`; Gemfile lives under `control-plane/`. Its local checkout is `~/Workspace/rarebit-one/jumpdrive-web` — the directory rename is done; the old `workspace-os` husk was removed 2026-07-14.)

After publishing a new version via `/publish-gem`, roll it out with the workspace-level `/rollout-gem standard_audit [<version>]` skill (defined at the rarebit-one workspace root, one directory above this repo). The canonical consumer matrix — including version constraints and any non-rubygems sources — lives in that skill's `SKILL.md`; the list here is a summary so version pins don't drift between two files.
