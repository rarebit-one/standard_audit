require "rails_helper"

RSpec.describe StandardAudit, ".record(raise: false)" do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }

  before { StandardAudit.reset_configuration!(replay_baseline: false) }

  after { StandardAudit.reset_configuration!(replay_baseline: false) }

  def break_writes!
    StandardAudit.config.before_write = ->(_entry) { raise ActiveRecord::StatementInvalid, "audit table on fire" }
  end

  it "raises by default" do
    break_writes!

    expect { StandardAudit.record("auth.failed", actor: user) }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "raises with raise: true" do
    break_writes!

    expect { StandardAudit.record("auth.failed", actor: user, raise: true) }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "returns nil and reports as handled with raise: false" do
    break_writes!
    allow(Rails.error).to receive(:report)
    allow(Rails.logger).to receive(:error)

    expect(StandardAudit.record("auth.failed", actor: user, raise: false)).to be_nil
    expect(Rails.error).to have_received(:report).with(
      an_instance_of(ActiveRecord::StatementInvalid),
      handled: true,
      context: { audit_action: "auth.failed", source: "StandardAudit.record" }
    )
    expect(Rails.logger).to have_received(:error).with(/auth\.failed.*audit table on fire/)
  end

  it "uses the configured audit_error_context_key" do
    break_writes!
    StandardAudit.config.audit_error_context_key = :audit_event
    allow(Rails.error).to receive(:report)

    StandardAudit.record("auth.failed", raise: false)

    expect(Rails.error).to have_received(:report).with(anything, hash_including(context: hash_including(audit_event: "auth.failed")))
  end

  it "writes normally and returns the row when nothing fails" do
    log = StandardAudit.record("auth.failed", actor: user, raise: false, metadata: { error_code: "AUTH_001" })

    expect(log).to be_persisted
    expect(log.metadata).to eq("error_code" => "AUTH_001")
    expect(log.metadata).not_to have_key("raise")
  end

  it "never swallows an error raised by the block in block form" do
    expect {
      StandardAudit.record("auth.block", actor: user, raise: false) { raise ArgumentError, "business failure" }
    }.to raise_error(ArgumentError, "business failure")
  end
end
