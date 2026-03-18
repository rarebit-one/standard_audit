require "rails_helper"

RSpec.describe StandardAudit::AuditLog, "ActiveSupport::Notifications integration", type: :model do
  # after_create_commit fires in transactional tests on Rails 7.1+ due to
  # run_commit_callbacks_on_first_saved_instances_in_transaction (default: true).

  it "instruments standard_audit.audit_log.created after commit" do
    events = []
    callback = lambda { |_name, _start, _finish, _id, payload| events << payload }

    log = nil
    ActiveSupport::Notifications.subscribed(callback, "standard_audit.audit_log.created") do
      log = StandardAudit::AuditLog.create!(
        event_type: "test.event",
        occurred_at: Time.current,
        actor_type: "User",
        target_type: "Order",
        scope_type: "Organisation"
      )
    end

    expect(events.size).to eq(1)
    expect(events.first).to include(
      id: log.id,
      event_type: "test.event",
      actor_type: "User",
      target_type: "Order",
      scope_type: "Organisation"
    )
  end

  it "does not emit notification on update" do
    log = StandardAudit::AuditLog.create!(event_type: "test.event", occurred_at: Time.current)

    events = []
    callback = lambda { |_name, _start, _finish, _id, payload| events << payload }

    ActiveSupport::Notifications.subscribed(callback, "standard_audit.audit_log.created") do
      log.update!(event_type: "test.updated")
    end

    expect(events).to be_empty
  end

  it "logs a warning and does not raise when instrumentation fails" do
    allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original
    allow(ActiveSupport::Notifications).to receive(:instrument)
      .with("standard_audit.audit_log.created", anything)
      .and_raise(RuntimeError, "boom")

    expect(Rails.logger).to receive(:warn).with(/Failed to emit event.*RuntimeError.*boom/)

    expect do
      StandardAudit::AuditLog.create!(event_type: "test.event", occurred_at: Time.current)
    end.not_to raise_error
  end
end
