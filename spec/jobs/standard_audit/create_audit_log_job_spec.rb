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

    def reference_selects
      selects = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _i, payload|
        next if payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])

        selects << payload[:sql] if payload[:sql].to_s.match?(/\ASELECT/i)
      end
      yield
      selects.reject { |sql| sql.include?("audit_logs") }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "writes the serialised references without locating the records (DBP-011)" do
      attrs = {
        "event_type" => "test.no_locate",
        "occurred_at" => Time.current.iso8601,
        "metadata" => {},
        "actor_gid" => user.to_global_id.to_s,
        "actor_type" => "User",
        "target_gid" => order.to_global_id.to_s,
        "target_type" => "Order",
        "scope_gid" => org.to_global_id.to_s,
        "scope_type" => "Organisation"
      }

      expect(reference_selects { described_class.new.perform(attrs) }).to be_empty

      log = StandardAudit::AuditLog.last
      expect(log.slice(:actor_gid, :actor_type, :target_gid, :target_type, :scope_gid, :scope_type).values)
        .to eq(attrs.values_at("actor_gid", "actor_type", "target_gid", "target_type", "scope_gid", "scope_type"))
      expect(StandardAudit::AuditLog.verify_chain[:valid]).to be(true)
    end

    it "keeps a gid whose class no longer exists" do
      attrs = {
        "event_type" => "test.removed_class",
        "occurred_at" => Time.current.iso8601,
        "metadata" => {},
        "actor_gid" => "gid://dummy/RemovedModel/1",
        "actor_type" => "RemovedModel"
      }

      expect { described_class.new.perform(attrs) }.to change(StandardAudit::AuditLog, :count).by(1)
      expect(StandardAudit::AuditLog.last.actor_gid).to eq("gid://dummy/RemovedModel/1")
    end

    it "still lets a before_checksum hook read the record" do
      seen = nil
      StandardAudit.config.before_checksum { |log| seen = log.actor }

      described_class.new.perform(
        "event_type" => "test.hook_reads_actor",
        "occurred_at" => Time.current.iso8601,
        "metadata" => {},
        "actor_gid" => user.to_global_id.to_s,
        "actor_type" => "User"
      )

      expect(seen).to eq(user)
    end
  end
end
