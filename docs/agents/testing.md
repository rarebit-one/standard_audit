# Testing

Moved verbatim from `AGENTS.md` in the P3 trim. `AGENTS.md` keeps a condensed command list.

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

CI also runs the suite on PostgreSQL (`test (postgres)`), because `jsonb`
reorders object keys and SQLite does not. Locally:

```bash
DATABASE_URL=postgres://user:pass@host:port/standard_audit_test bundle exec rspec
```

The helper DROPS and recreates the `public` schema of that database on boot
(it refuses a database whose name lacks `test`), so point it at a throwaway.

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
