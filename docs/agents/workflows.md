# Common workflows

Moved verbatim from `AGENTS.md` in the P3 trim.

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
