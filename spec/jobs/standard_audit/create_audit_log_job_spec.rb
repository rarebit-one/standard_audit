require "rails_helper"

RSpec.describe StandardAudit::CreateAuditLogJob, type: :job do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:order) { Order.create!(total: 99.99) }
  let(:org) { Organisation.create!(name: "Acme") }

  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  after do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  describe "#perform" do
    it "creates audit log from serialized attributes" do
      attrs = {
        "event_type" => "order.created",
        "occurred_at" => Time.current.iso8601,
        "request_id" => "req-123",
        "ip_address" => "192.168.1.1",
        "user_agent" => "TestAgent",
        "session_id" => "sess-abc",
        "metadata" => { "total" => 99.99 },
        "actor_gid" => user.to_global_id.to_s,
        "actor_type" => "User",
        "target_gid" => order.to_global_id.to_s,
        "target_type" => "Order",
        "scope_gid" => org.to_global_id.to_s,
        "scope_type" => "Organisation"
      }

      expect {
        described_class.new.perform(attrs)
      }.to change(StandardAudit::AuditLog, :count).by(1)

      log = StandardAudit::AuditLog.last
      expect(log.event_type).to eq("order.created")
      expect(log.request_id).to eq("req-123")
      expect(log.metadata).to eq({ "total" => 99.99 })
    end

    it "locates actor, target, and scope from GlobalID strings" do
      attrs = {
        "event_type" => "test.gid",
        "occurred_at" => Time.current.iso8601,
        "metadata" => {},
        "actor_gid" => user.to_global_id.to_s,
        "actor_type" => "User",
        "target_gid" => order.to_global_id.to_s,
        "target_type" => "Order",
        "scope_gid" => org.to_global_id.to_s,
        "scope_type" => "Organisation"
      }

      described_class.new.perform(attrs)

      log = StandardAudit::AuditLog.last
      expect(log.actor).to eq(user)
      expect(log.target).to eq(order)
      expect(log.scope).to eq(org)
    end

    it "handles missing records gracefully (nil instead of raising)" do
      attrs = {
        "event_type" => "test.missing",
        "occurred_at" => Time.current.iso8601,
        "metadata" => {},
        "actor_gid" => "gid://dummy/User/99999",
        "actor_type" => "User",
        "target_gid" => nil,
        "target_type" => nil,
        "scope_gid" => nil,
        "scope_type" => nil
      }

      expect {
        described_class.new.perform(attrs)
      }.to change(StandardAudit::AuditLog, :count).by(1)

      log = StandardAudit::AuditLog.last
      # The GID should be preserved even though the record doesn't exist
      expect(log.actor_gid).to eq("gid://dummy/User/99999")
    end

    it "uses configured queue name" do
      StandardAudit.configure do |config|
        config.queue_name = :audit_logs
      end

      job = described_class.new
      expect(job.queue_name).to eq("audit_logs")
    end

    it "handles nil GID values" do
      attrs = {
        "event_type" => "test.nil_gids",
        "occurred_at" => Time.current.iso8601,
        "metadata" => {},
        "actor_gid" => nil,
        "actor_type" => nil,
        "target_gid" => nil,
        "target_type" => nil,
        "scope_gid" => nil,
        "scope_type" => nil
      }

      expect {
        described_class.new.perform(attrs)
      }.to change(StandardAudit::AuditLog, :count).by(1)

      log = StandardAudit::AuditLog.last
      expect(log.actor_gid).to be_nil
      expect(log.target_gid).to be_nil
      expect(log.scope_gid).to be_nil
    end
  end
end
