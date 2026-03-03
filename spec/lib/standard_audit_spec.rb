require "rails_helper"

RSpec.describe StandardAudit do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:order) { Order.create!(total: 99.99) }
  let(:org) { Organisation.create!(name: "Acme") }

  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  after do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  describe ".record" do
    it "creates audit log with explicit actor, target, and scope" do
      log = StandardAudit.record("order.created", actor: user, target: order, scope: org)

      expect(log).to be_a(StandardAudit::AuditLog)
      expect(log).to be_persisted
      expect(log.event_type).to eq("order.created")
      expect(log.actor).to eq(user)
      expect(log.target).to eq(order)
      expect(log.scope).to eq(org)
    end

    it "auto-resolves actor from Current when not provided" do
      StandardAudit.configure do |config|
        config.current_actor_resolver = -> { user }
      end

      log = StandardAudit.record("auto.actor.test", target: order)

      expect(log.actor).to eq(user)
    end

    it "auto-resolves request context from Current" do
      StandardAudit.configure do |config|
        config.current_request_id_resolver = -> { "req-auto" }
        config.current_ip_address_resolver = -> { "192.168.1.100" }
        config.current_user_agent_resolver = -> { "Mozilla/5.0" }
        config.current_session_id_resolver = -> { "sess-auto" }
      end

      log = StandardAudit.record("context.test", actor: user)

      expect(log.request_id).to eq("req-auto")
      expect(log.ip_address).to eq("192.168.1.100")
      expect(log.user_agent).to eq("Mozilla/5.0")
      expect(log.session_id).to eq("sess-auto")
    end

    it "respects config.enabled = false" do
      StandardAudit.config.enabled = false

      result = StandardAudit.record("disabled.test", actor: user)

      expect(result).to be_nil
      expect(StandardAudit::AuditLog.count).to eq(0)
    end

    it "uses async job when config.async = true" do
      StandardAudit.config.async = true

      expect(StandardAudit::CreateAuditLogJob).to receive(:perform_later)
        .with(hash_including("event_type" => "async.test"))

      StandardAudit.record("async.test", actor: user)
    end

    it "filters sensitive metadata keys" do
      log = StandardAudit.record("sensitive.test", actor: user, metadata: {
        action: "login",
        password: "secret",
        token: "abc123",
        details: "ok"
      })

      expect(log.metadata).to include("action" => "login", "details" => "ok")
      expect(log.metadata).not_to have_key("password")
      expect(log.metadata).not_to have_key("token")
    end

    it "instruments via AS::Notifications in block form" do
      events = []
      subscription = ActiveSupport::Notifications.subscribe("order.created") do |event|
        events << event
      end

      StandardAudit.record("order.created", actor: user, target: order, metadata: { total: 99 }) do
        # block body
      end

      expect(events.size).to eq(1)
      expect(events.first.name).to eq("order.created")

      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "stores metadata as hash" do
      log = StandardAudit.record("metadata.test", actor: user, metadata: {
        action: "update",
        changes: { name: "New Name" }
      })

      expect(log.metadata["action"]).to eq("update")
      expect(log.metadata["changes"]).to eq({ "name" => "New Name" })
    end

    it "sets occurred_at automatically" do
      freeze_time do
        log = StandardAudit.record("time.test", actor: user)
        expect(log.occurred_at).to be_within(1.second).of(Time.current)
      end
    end
  end

  describe ".configure" do
    it "yields the configuration" do
      StandardAudit.configure do |config|
        config.async = true
        config.queue_name = :audit
      end

      expect(StandardAudit.config.async).to be true
      expect(StandardAudit.config.queue_name).to eq(:audit)
    end
  end

  describe ".config" do
    it "returns a Configuration instance" do
      expect(StandardAudit.config).to be_a(StandardAudit::Configuration)
    end

    it "returns the same instance on subsequent calls" do
      expect(StandardAudit.config).to equal(StandardAudit.config)
    end
  end
end
