require "rails_helper"

RSpec.describe StandardAudit::Subscriber do
  let(:subscriber) { described_class.new }

  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
    StandardAudit.instance_variable_set(:@subscriber, nil)
  end

  after do
    subscriber.teardown!
    StandardAudit.instance_variable_set(:@configuration, nil)
    StandardAudit.instance_variable_set(:@subscriber, nil)
  end

  describe "#setup!" do
    it "subscribes to all configured patterns" do
      StandardAudit.configure do |config|
        config.subscribe_to "audit.test.**"
        config.subscribe_to "user.**"
      end

      subscriber.setup!

      expect(subscriber.subscriptions.size).to eq(2)
    end
  end

  describe "event handling" do
    let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
    let(:order) { Order.create!(total: 99.99) }
    let(:org) { Organisation.create!(name: "Acme") }

    before do
      StandardAudit.configure do |config|
        config.subscribe_to "audit.test"
      end
      subscriber.setup!
    end

    it "creates audit log when event fires" do
      expect {
        ActiveSupport::Notifications.instrument("audit.test", { actor: user })
      }.to change(StandardAudit::AuditLog, :count).by(1)

      log = StandardAudit::AuditLog.last
      expect(log.event_type).to eq("audit.test")
    end

    it "extracts actor using configured extractor" do
      ActiveSupport::Notifications.instrument("audit.test", { actor: user })

      log = StandardAudit::AuditLog.last
      expect(log.actor).to eq(user)
      expect(log.actor_type).to eq("User")
    end

    it "extracts target using configured extractor" do
      ActiveSupport::Notifications.instrument("audit.test", { actor: user, target: order })

      log = StandardAudit::AuditLog.last
      expect(log.target).to eq(order)
      expect(log.target_type).to eq("Order")
    end

    it "extracts scope using configured extractor" do
      ActiveSupport::Notifications.instrument("audit.test", { actor: user, scope: org })

      log = StandardAudit::AuditLog.last
      expect(log.scope).to eq(org)
      expect(log.scope_type).to eq("Organisation")
    end

    it "filters sensitive metadata keys" do
      ActiveSupport::Notifications.instrument("audit.test", {
        actor: user,
        action: "login",
        password: "secret123",
        token: "abc"
      })

      log = StandardAudit::AuditLog.last
      expect(log.metadata).to have_key("action")
      expect(log.metadata).not_to have_key("password")
      expect(log.metadata).not_to have_key("token")
    end

    it "falls back to Current attributes when payload values are nil" do
      # Define a temporary Current class
      stub_const("Current", Class.new(ActiveSupport::CurrentAttributes) {
        attribute :user, :request_id, :ip_address, :user_agent, :session_id
      })

      StandardAudit.instance_variable_set(:@configuration, nil)
      StandardAudit.configure do |config|
        config.subscribe_to "audit.fallback_test"
        config.current_actor_resolver = -> { Current.user }
        config.current_request_id_resolver = -> { Current.request_id }
        config.current_ip_address_resolver = -> { Current.ip_address }
      end

      old_subs = subscriber.subscriptions.dup
      subscriber.teardown!

      new_subscriber = StandardAudit::Subscriber.new
      new_subscriber.setup!

      Current.user = user
      Current.request_id = "req-from-current"
      Current.ip_address = "10.0.0.1"

      ActiveSupport::Notifications.instrument("audit.fallback_test", {})

      log = StandardAudit::AuditLog.last
      expect(log.actor).to eq(user)
      expect(log.request_id).to eq("req-from-current")
      expect(log.ip_address).to eq("10.0.0.1")

      new_subscriber.teardown!
      Current.reset
    end

    it "respects enabled = false (no log created)" do
      StandardAudit.config.enabled = false

      expect {
        ActiveSupport::Notifications.instrument("audit.test", { actor: user })
      }.not_to change(StandardAudit::AuditLog, :count)
    end

    it "uses async job when config.async = true" do
      StandardAudit.config.async = true

      expect(StandardAudit::CreateAuditLogJob).to receive(:perform_later).with(hash_including("event_type" => "audit.test"))

      ActiveSupport::Notifications.instrument("audit.test", { actor: user })
    end

    it "handles errors gracefully (logs error, doesn't raise)" do
      allow(StandardAudit::AuditLog).to receive(:new).and_raise(StandardError, "DB error")
      allow(Rails.logger).to receive(:error)

      expect {
        ActiveSupport::Notifications.instrument("audit.test", { actor: user })
      }.not_to raise_error

      expect(Rails.logger).to have_received(:error).with(/StandardAudit.*DB error/)
    end

    it "uses custom metadata_builder when configured" do
      StandardAudit.config.metadata_builder = ->(raw) {
        raw.merge(custom_key: "added_by_builder")
      }

      ActiveSupport::Notifications.instrument("audit.test", {
        actor: user,
        action: "test"
      })

      log = StandardAudit::AuditLog.last
      expect(log.metadata["custom_key"]).to eq("added_by_builder")
    end
  end

  describe "#teardown!" do
    it "clears all subscriptions" do
      StandardAudit.configure do |config|
        config.subscribe_to "audit.teardown_test"
      end
      subscriber.setup!

      expect(subscriber.subscriptions).not_to be_empty
      subscriber.teardown!
      expect(subscriber.subscriptions).to be_empty
    end
  end
end
