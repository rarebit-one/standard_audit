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

  describe "config.error_reporter" do
    it "receives the error and context instead of Rails.error" do
      break_writes!
      reported = []
      StandardAudit.config.error_reporter = ->(error, context) { reported << [error, context] }
      allow(Rails.error).to receive(:report)

      expect(StandardAudit.record("auth.failed", actor: user, raise: false)).to be_nil

      expect(reported.sole.first).to be_a(ActiveRecord::StatementInvalid)
      expect(reported.sole.last).to eq(audit_action: "auth.failed", source: "StandardAudit.record")
      expect(Rails.error).not_to have_received(:report)
    end

    it "never turns a swallowed failure into a raised one when the reporter itself raises" do
      break_writes!
      StandardAudit.config.error_reporter = ->(_error, _context) { raise "tracker down" }
      allow(Rails.logger).to receive(:error)

      expect(StandardAudit.record("auth.failed", actor: user, raise: false)).to be_nil
      expect(Rails.logger).to have_received(:error).with(/Error reporting audit failure: RuntimeError: tracker down/)
    end

    it "is used by the subscriber, before_checksum and audit! report sites too" do
      reported = []
      StandardAudit.config.error_reporter = ->(error, context) { reported << [error.message, context] }
      StandardAudit.config.before_checksum { |_log| raise "hook broke" }
      StandardAudit::Operation::Audit.handle_write_error(StandardError.new("op broke"), action: "x.y", operation: Object.new)
      StandardAudit.report_write_error(StandardError.new("sub broke"), "a.b", subscriber: "S")
      StandardAudit.record("hooked.event", actor: user)

      expect(reported).to contain_exactly(
        ["op broke", { audit_action: "x.y", operation: "Object" }],
        ["sub broke", { audit_action: "a.b", subscriber: "S" }],
        ["hook broke", { audit_action: "hooked.event" }]
      )
    end
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
