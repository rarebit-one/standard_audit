# Security notes

Moved verbatim from `AGENTS.md` in the P3 trim, except the last bullet, which was corrected (see the PR that introduced this file).

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
- `bundle exec brakeman --no-pager --force` runs as part of the pre-push
  lefthook checks (`lefthook.yml`). `bundle exec bundler-audit --update` runs
  in CI (`.github/workflows/ci.yml`), not in lefthook.
