require "rails_helper"

RSpec.describe StandardAudit::AuditScope do
  let(:org) { Organisation.create!(name: "Acme") }
  let(:other_org) { Organisation.create!(name: "Globex") }
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }

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

  describe "#scoped_audit_logs" do
    it "returns logs scoped to the record" do
      log1 = create_log(actor: user, scope: org)
      log2 = create_log(actor: user, scope: org, event_type: "another.event")
      _log3 = create_log(actor: user, scope: other_org)
      _log4 = create_log(actor: user)

      expect(org.scoped_audit_logs).to contain_exactly(log1, log2)
    end

    it "returns empty relation when no logs are scoped" do
      expect(org.scoped_audit_logs).to be_empty
    end
  end
end
