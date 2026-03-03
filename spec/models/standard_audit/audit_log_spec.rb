require "rails_helper"

RSpec.describe StandardAudit::AuditLog, type: :model do
  describe "validations" do
    it "validates presence of event_type" do
      log = StandardAudit::AuditLog.new(occurred_at: Time.current)
      expect(log).not_to be_valid
      expect(log.errors[:event_type]).to include("can't be blank")
    end

    it "validates presence of occurred_at" do
      log = StandardAudit::AuditLog.new(event_type: "test.event")
      expect(log).not_to be_valid
      expect(log.errors[:occurred_at]).to include("can't be blank")
    end

    it "is valid with event_type and occurred_at" do
      log = StandardAudit::AuditLog.new(event_type: "test.event", occurred_at: Time.current)
      expect(log).to be_valid
    end
  end

  describe "actor assignment" do
    let(:user) { User.create!(name: "Alice", email: "alice@example.com") }

    it "sets actor via record assignment using GlobalID" do
      log = StandardAudit::AuditLog.new(event_type: "test.event", occurred_at: Time.current)
      log.actor = user

      expect(log.actor_gid).to eq(user.to_global_id.to_s)
      expect(log.actor_type).to eq("User")
    end

    it "retrieves actor from GlobalID" do
      log = StandardAudit::AuditLog.create!(event_type: "test.event", occurred_at: Time.current)
      log.actor = user
      log.save!

      reloaded = StandardAudit::AuditLog.find(log.id)
      expect(reloaded.actor).to eq(user)
    end

    it "handles nil actor gracefully" do
      log = StandardAudit::AuditLog.new(event_type: "test.event", occurred_at: Time.current)
      log.actor = nil

      expect(log.actor_gid).to be_nil
      expect(log.actor_type).to be_nil
      expect(log.actor).to be_nil
    end

    it "handles deleted actor gracefully" do
      log = StandardAudit::AuditLog.create!(event_type: "test.event", occurred_at: Time.current)
      log.actor = user
      log.save!

      user.destroy!

      reloaded = StandardAudit::AuditLog.find(log.id)
      expect(reloaded.actor).to be_nil
    end
  end

  describe "target assignment" do
    let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
    let(:order) { Order.create!(total: 99.99) }

    it "sets target via record assignment" do
      log = StandardAudit::AuditLog.new(event_type: "test.event", occurred_at: Time.current)
      log.target = order

      expect(log.target_gid).to eq(order.to_global_id.to_s)
      expect(log.target_type).to eq("Order")
    end

    it "retrieves target from GlobalID" do
      log = StandardAudit::AuditLog.create!(event_type: "test.event", occurred_at: Time.current)
      log.target = order
      log.save!

      reloaded = StandardAudit::AuditLog.find(log.id)
      expect(reloaded.target).to eq(order)
    end

    it "handles nil target gracefully" do
      log = StandardAudit::AuditLog.new(event_type: "test.event", occurred_at: Time.current)
      log.target = nil

      expect(log.target_gid).to be_nil
      expect(log.target_type).to be_nil
      expect(log.target).to be_nil
    end

    it "handles deleted target gracefully" do
      log = StandardAudit::AuditLog.create!(event_type: "test.event", occurred_at: Time.current)
      log.target = order
      log.save!

      order.destroy!

      reloaded = StandardAudit::AuditLog.find(log.id)
      expect(reloaded.target).to be_nil
    end
  end

  describe "scope assignment" do
    let(:org) { Organisation.create!(name: "Acme") }

    it "sets scope via record assignment" do
      log = StandardAudit::AuditLog.new(event_type: "test.event", occurred_at: Time.current)
      log.scope = org

      expect(log.scope_gid).to eq(org.to_global_id.to_s)
      expect(log.scope_type).to eq("Organisation")
    end

    it "retrieves scope from GlobalID" do
      log = StandardAudit::AuditLog.create!(event_type: "test.event", occurred_at: Time.current)
      log.scope = org
      log.save!

      reloaded = StandardAudit::AuditLog.find(log.id)
      expect(reloaded.scope).to eq(org)
    end

    it "handles nil scope gracefully" do
      log = StandardAudit::AuditLog.new(event_type: "test.event", occurred_at: Time.current)
      log.scope = nil

      expect(log.scope_gid).to be_nil
      expect(log.scope_type).to be_nil
      expect(log.scope).to be_nil
    end

    it "handles deleted scope gracefully" do
      log = StandardAudit::AuditLog.create!(event_type: "test.event", occurred_at: Time.current)
      log.scope = org
      log.save!

      org.destroy!

      reloaded = StandardAudit::AuditLog.find(log.id)
      expect(reloaded.scope).to be_nil
    end
  end
end
