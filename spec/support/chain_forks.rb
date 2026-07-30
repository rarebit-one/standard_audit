# Builds the row state that concurrent audit writers produce, using only the
# model's own callbacks and no stubs. See
# spec/models/standard_audit/audit_log_concurrency_spec.rb for why this is
# simulated rather than threaded (SQLite serialises writers, so the gem's own
# backend cannot exhibit the race at all).
#
# The sleeps keep UUIDv7 ids and created_at timestamps monotonic, so the order
# verify_chain walks is the order the rows were written.
module ChainForks
  def create_log(event_type, **attrs)
    sleep(0.002)
    StandardAudit::AuditLog.create!(event_type: event_type, occurred_at: Time.current, **attrs)
  end

  # N records that each ran the before_create chain against the same committed
  # snapshot — what N concurrent transactions do — none of them persisted yet.
  def build_concurrent_writers(*event_types)
    event_types.map do |event_type|
      sleep(0.002)
      StandardAudit::AuditLog.new(event_type: event_type, occurred_at: Time.current).tap do |log|
        log.run_callbacks(:create) { nil }
      end
    end
  end

  def commit(writers)
    writers.each do |writer|
      sleep(0.002)
      writer.save!
    end
  end

  # Turns every row into a pre-0.8 row: written by a chained writer, but with no
  # record of which parent it used.
  def forget_declared_parents
    StandardAudit::AuditLog.update_all(previous_checksum: nil)
  end
end

RSpec.configure { |config| config.include ChainForks }
