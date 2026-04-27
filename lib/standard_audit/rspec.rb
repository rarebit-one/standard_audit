require "standard_audit"

# StandardAudit state reset between examples.
#
# - Clears the thread-local batch buffer so a spec that exits inside a
#   `StandardAudit.batch { ... }` block (e.g. via an unhandled error or
#   abort) cannot leak buffered records into the next example.
# - Resets the Configuration via `StandardAudit.reset_configuration!` so
#   that mutations to `StandardAudit.config` (subscriptions, sensitive
#   keys, async flag, custom resolvers, etc.) do not bleed across specs.
#   Consumers that customise configuration must re-call
#   `StandardAudit.configure { |c| ... }` from a `before` hook in their
#   own suite if they need a non-default baseline.
#
# The memoized `Subscriber` and `EventSubscriber` instances are *not*
# torn down here — they are wired up at engine boot via initializers and
# rebuilding them per-example would unsubscribe from
# `ActiveSupport::Notifications` / `Rails.event` for the rest of the run.
# Specs that need to assert on subscriber behaviour should manage that
# locally.
#
# Intentionally `before(:each)` rather than `after(:each)` so the reset
# always runs even when a previous example aborted in an after hook.
RSpec.configure do |config|
  config.before(:each) do
    Thread.current[:standard_audit_batch] = nil
    StandardAudit.reset_configuration!
  end
end
