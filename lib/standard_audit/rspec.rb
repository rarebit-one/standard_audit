require "standard_audit"

# StandardAudit state reset between examples.
#
# - Clears the thread-local batch buffer so a spec that exits inside a
#   `StandardAudit.batch { ... }` block (e.g. via an unhandled error or
#   abort) cannot leak buffered records into the next example.
# - Resets the Configuration via `StandardAudit.reset_configuration!` so
#   that mutations to `StandardAudit.config` (subscriptions, sensitive
#   keys, async flag, custom resolvers, etc.) do not bleed across specs.
#
# IMPORTANT — declare your configuration as a baseline. The reset restores
# gem defaults, and the config object holds *behaviour*, not just data:
# `before_checksum_hooks` live there. A suite that installs this plugin
# without a baseline silently loses its write-time hooks after the first
# example, and the specs that would have caught it pass vacuously.
#
# So in `config/initializers/standard_audit.rb`, use:
#
#   StandardAudit.configure(baseline: true) do |config|
#     config.subscribe_to "myapp.**"
#     config.before_checksum :backfill_scope
#   end
#
# `reset_configuration!` replays that block onto the fresh Configuration,
# so every example starts from your app's real configuration. There is
# nothing to re-apply by hand in a `before` hook.
#
# The memoized `Subscriber` and `EventSubscriber` instances are *not*
# torn down here — they are wired up at engine boot via initializers and
# rebuilding them per-example would unsubscribe from
# `ActiveSupport::Notifications` / `Rails.event` for the rest of the run.
# Specs that need to assert on subscriber behaviour should manage that
# locally.
#
# Intentionally `before(:example)` rather than `after(:example)` so the
# reset always runs even when a previous example aborted in an after hook.
RSpec.configure do |config|
  config.before(:example) do
    Thread.current[:standard_audit_batch] = nil
    StandardAudit.reset_configuration!
  end
end
