require "rails_helper"

RSpec.describe StandardAudit::AuditLog, "GDPR", type: :model do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:other_user) { User.create!(name: "Bob", email: "bob@example.com") }
  let(:order) { Order.create!(total: 99.99) }
  let(:org) { Organisation.create!(name: "Acme") }

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

  describe ".anonymize_actor!" do
    it "replaces actor_gid with '[anonymized]'" do
      log = create_log(actor: user, event_type: "user.login")

      described_class.anonymize_actor!(user)

      log.reload
      expect(log.actor_gid).to eq("[anonymized]")
    end

    it "clears ip_address, user_agent, session_id" do
      log = create_log(
        actor: user,
        ip_address: "192.168.1.1",
        user_agent: "Mozilla/5.0",
        session_id: "sess-123"
      )

      described_class.anonymize_actor!(user)

      log.reload
      expect(log.ip_address).to be_nil
      expect(log.user_agent).to be_nil
      expect(log.session_id).to be_nil
    end

    it "strips configured metadata keys from JSON" do
      log = create_log(
        actor: user,
        metadata: { "email" => "alice@example.com", "name" => "Alice", "action" => "login", "ip_address" => "1.2.3.4" }
      )

      described_class.anonymize_actor!(user)

      log.reload
      expect(log.metadata).to include("action" => "login")
      expect(log.metadata).not_to have_key("email")
      expect(log.metadata).not_to have_key("name")
      expect(log.metadata).not_to have_key("ip_address")
    end

    it "also anonymizes target_gid references" do
      log = create_log(
        actor: other_user,
        target: user,
        ip_address: "10.0.0.1",
        user_agent: "Agent",
        session_id: "sess-target"
      )

      described_class.anonymize_actor!(user)

      log.reload
      expect(log.target_gid).to eq("[anonymized]")
      expect(log.target_type).to eq("[anonymized]")
      expect(log.ip_address).to be_nil
      expect(log.user_agent).to be_nil
      expect(log.session_id).to be_nil
    end

    it "returns count of affected records" do
      create_log(actor: user)
      create_log(actor: user)
      create_log(target: user)
      create_log(actor: other_user) # not affected

      count = described_class.anonymize_actor!(user)
      expect(count).to eq(3)
    end

    it "does not affect logs for other actors" do
      log = create_log(actor: other_user, ip_address: "10.0.0.1", user_agent: "Chrome")

      described_class.anonymize_actor!(user)

      log.reload
      expect(log.actor_gid).to eq(other_user.to_global_id.to_s)
      expect(log.ip_address).to eq("10.0.0.1")
      expect(log.user_agent).to eq("Chrome")
    end

    it "handles custom anonymizable_metadata_keys" do
      StandardAudit.configure do |config|
        config.anonymizable_metadata_keys = %i[email phone]
      end

      log = create_log(
        actor: user,
        metadata: { "email" => "alice@example.com", "phone" => "555-1234", "action" => "login", "name" => "Alice" }
      )

      described_class.anonymize_actor!(user)

      log.reload
      expect(log.metadata).not_to have_key("email")
      expect(log.metadata).not_to have_key("phone")
      expect(log.metadata).to include("action" => "login")
      expect(log.metadata).to include("name" => "Alice")
    end
  end

  describe ".export_for_actor" do
    it "includes logs as both actor and target" do
      create_log(actor: user, event_type: "user.login")
      create_log(actor: other_user, target: user, event_type: "admin.viewed_user")
      create_log(actor: other_user, target: order, event_type: "unrelated")

      export = described_class.export_for_actor(user)

      expect(export[:total_records]).to eq(2)
    end

    it "outputs valid JSON with expected structure" do
      create_log(
        actor: user,
        event_type: "user.login",
        ip_address: "192.168.1.1",
        user_agent: "Chrome",
        request_id: "req-1",
        metadata: { "action" => "login" }
      )

      export = described_class.export_for_actor(user)

      expect(export).to have_key(:subject)
      expect(export).to have_key(:exported_at)
      expect(export).to have_key(:total_records)
      expect(export).to have_key(:records)

      expect(export[:subject]).to eq(user.to_global_id.to_s)
      expect(export[:total_records]).to eq(1)
      expect(export[:records].size).to eq(1)

      record = export[:records].first
      expect(record[:event_type]).to eq("user.login")
      expect(record[:ip_address]).to eq("192.168.1.1")
      expect(record[:user_agent]).to eq("Chrome")
      expect(record[:request_id]).to eq("req-1")
      expect(record[:metadata]).to eq({ "action" => "login" })
      expect(record[:occurred_at]).to be_a(String) # ISO8601

      # Verify it's valid JSON
      json = JSON.generate(export)
      parsed = JSON.parse(json)
      expect(parsed["subject"]).to eq(user.to_global_id.to_s)
    end

    it "returns empty records when no logs exist" do
      export = described_class.export_for_actor(user)

      expect(export[:total_records]).to eq(0)
      expect(export[:records]).to be_empty
    end

    it "orders records chronologically" do
      create_log(actor: user, event_type: "second", occurred_at: 1.hour.ago)
      create_log(actor: user, event_type: "first", occurred_at: 2.hours.ago)

      export = described_class.export_for_actor(user)

      expect(export[:records].first[:event_type]).to eq("first")
      expect(export[:records].last[:event_type]).to eq("second")
    end
  end
end
