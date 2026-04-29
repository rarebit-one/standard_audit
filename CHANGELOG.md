# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
