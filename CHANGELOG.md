# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
