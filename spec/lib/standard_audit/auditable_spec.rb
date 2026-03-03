require "rails_helper"

RSpec.describe StandardAudit::Auditable do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:other_user) { User.create!(name: "Bob", email: "bob@example.com") }
  let(:order) { Order.create!(total: 99.99) }

  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  after do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  def create_log(attrs = {})
    log = StandardAudit::AuditLog.new({
      event_type: "test.event",
      occurred_at: Time.current
    }.merge(attrs.except(:actor, :target, :scope)))
    log.actor = attrs[:actor] if attrs.key?(:actor)
    log.target = attrs[:target] if attrs.key?(:target)
    log.scope = attrs[:scope] if attrs.key?(:scope)
    log.save!
    log
  end

  describe "#audit_logs_as_actor" do
    it "returns logs where record is actor" do
      log1 = create_log(actor: user)
      _log2 = create_log(actor: other_user)
      _log3 = create_log(target: user)

      expect(user.audit_logs_as_actor).to contain_exactly(log1)
    end
  end

  describe "#audit_logs_as_target" do
    it "returns logs where record is target" do
      _log1 = create_log(actor: user)
      log2 = create_log(target: user)
      _log3 = create_log(target: order)

      expect(user.audit_logs_as_target).to contain_exactly(log2)
    end
  end

  describe "#audit_logs" do
    it "returns logs where record is actor OR target" do
      log1 = create_log(actor: user)
      log2 = create_log(target: user)
      _log3 = create_log(actor: other_user, target: order)

      expect(user.audit_logs).to contain_exactly(log1, log2)
    end
  end

  describe "#record_audit" do
    it "creates log with self as actor" do
      expect {
        user.record_audit("user.action", target: order, metadata: { action: "test" })
      }.to change(StandardAudit::AuditLog, :count).by(1)

      log = StandardAudit::AuditLog.last
      expect(log.actor).to eq(user)
      expect(log.target).to eq(order)
      expect(log.event_type).to eq("user.action")
      expect(log.metadata["action"]).to eq("test")
    end

    it "accepts scope parameter" do
      org = Organisation.create!(name: "Acme")
      user.record_audit("user.scoped", target: order, scope: org)

      log = StandardAudit::AuditLog.last
      expect(log.scope).to eq(org)
    end
  end
end
