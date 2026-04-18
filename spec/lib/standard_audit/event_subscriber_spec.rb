require "rails_helper"

RSpec.describe StandardAudit::EventSubscriber, skip: !Rails.respond_to?(:event) do
  let(:subscriber) { described_class.new }
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:order) { Order.create!(total: 99.99) }
  let(:org) { Organisation.create!(name: "Acme") }

  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
    StandardAudit.instance_variable_set(:@event_subscriber, nil)
    Rails.event.subscribers.each { |s| Rails.event.unsubscribe(s[:subscriber]) }
    Rails.event.clear_context
    Rails.event.subscribe(subscriber)

    StandardAudit.configure do |config|
      config.subscribe_to "audit.event.**"
    end
  end

  after do
    Rails.event.unsubscribe(subscriber)
    Rails.event.clear_context
    StandardAudit.instance_variable_set(:@configuration, nil)
    StandardAudit.instance_variable_set(:@event_subscriber, nil)
  end

  describe "#emit" do
    it "persists an audit log when the event name matches a subscription" do
      expect {
        Rails.event.notify("audit.event.demo", actor: user)
      }.to change(StandardAudit::AuditLog, :count).by(1)

      log = StandardAudit::AuditLog.last
      expect(log.event_type).to eq("audit.event.demo")
      expect(log.actor).to eq(user)
    end

    it "ignores events that do not match any subscription" do
      expect {
        Rails.event.notify("other.event", actor: user)
      }.not_to change(StandardAudit::AuditLog, :count)
    end

    it "extracts target and scope via configured extractors" do
      Rails.event.notify("audit.event.created", actor: user, target: order, scope: org)

      log = StandardAudit::AuditLog.last
      expect(log.target).to eq(order)
      expect(log.scope).to eq(org)
    end

    it "stores remaining payload keys as metadata" do
      Rails.event.notify("audit.event.update", actor: user, field: "name", value: "new")

      log = StandardAudit::AuditLog.last
      expect(log.metadata).to include("field" => "name", "value" => "new")
    end

    it "filters sensitive keys from metadata" do
      Rails.event.notify("audit.event.login",
        actor: user,
        action: "login",
        password: "hunter2",
        token: "abc")

      log = StandardAudit::AuditLog.last
      expect(log.metadata).to include("action" => "login")
      expect(log.metadata).not_to have_key("password")
      expect(log.metadata).not_to have_key("token")
    end

    it "captures context as request_id / ip_address / user_agent / session_id" do
      Rails.event.set_context(
        request_id: "req-123",
        ip_address: "10.0.0.9",
        user_agent: "spec-agent/1.0",
        session_id: "sess-xyz"
      )

      Rails.event.notify("audit.event.ctx", actor: user)

      log = StandardAudit::AuditLog.last
      expect(log.request_id).to eq("req-123")
      expect(log.ip_address).to eq("10.0.0.9")
      expect(log.user_agent).to eq("spec-agent/1.0")
      expect(log.session_id).to eq("sess-xyz")
    end

    it "stores tags under metadata[:_tags]" do
      Rails.event.tagged("checkout") do
        Rails.event.tagged(step: "payment") do
          Rails.event.notify("audit.event.step", actor: user)
        end
      end

      log = StandardAudit::AuditLog.last
      expect(log.metadata["_tags"]).to include("checkout" => true, "step" => "payment")
    end

    it "stores source_location under metadata[:_source]" do
      Rails.event.notify("audit.event.source", actor: user)

      log = StandardAudit::AuditLog.last
      expect(log.metadata["_source"]).to include("filepath", "lineno", "label")
    end

    it "respects config.enabled = false" do
      StandardAudit.config.enabled = false

      expect {
        Rails.event.notify("audit.event.demo", actor: user)
      }.not_to change(StandardAudit::AuditLog, :count)
    end

    it "uses async job when config.async = true" do
      StandardAudit.config.async = true

      expect(StandardAudit::CreateAuditLogJob).to receive(:perform_later).with(
        hash_including("event_type" => "audit.event.async")
      )

      Rails.event.notify("audit.event.async", actor: user)
    end

    it "does not raise when persistence fails" do
      allow(StandardAudit::AuditLog).to receive(:new).and_raise(StandardError, "boom")
      allow(Rails.logger).to receive(:error)

      expect {
        Rails.event.notify("audit.event.err", actor: user)
      }.not_to raise_error

      expect(Rails.logger).to have_received(:error).with(/StandardAudit.*boom/)
    end

    it "applies metadata_builder before sensitive filtering" do
      StandardAudit.config.metadata_builder = ->(raw) { raw.merge(builder_added: true) }

      Rails.event.notify("audit.event.builder", actor: user, original: "kept")

      log = StandardAudit::AuditLog.last
      expect(log.metadata).to include("original" => "kept", "builder_added" => true)
    end

    it "falls back to Current resolvers when context omits fields" do
      fallback_user = user
      StandardAudit.instance_variable_set(:@configuration, nil)
      StandardAudit.configure do |config|
        config.subscribe_to "audit.event.**"
        config.current_actor_resolver = -> { fallback_user }
        config.current_request_id_resolver = -> { "req-from-current" }
      end

      Rails.event.notify("audit.event.fallback")

      log = StandardAudit::AuditLog.last
      expect(log.actor).to eq(fallback_user)
      expect(log.request_id).to eq("req-from-current")
    end
  end

  describe "pattern matching" do
    it "matches a single segment with '*'" do
      StandardAudit.instance_variable_set(:@configuration, nil)
      StandardAudit.configure { |c| c.subscribe_to "audit.event.*" }

      Rails.event.notify("audit.event.created", actor: user)
      Rails.event.notify("audit.event.nested.deep", actor: user)

      expect(StandardAudit::AuditLog.pluck(:event_type)).to eq(["audit.event.created"])
    end

    it "matches any remainder with '**'" do
      StandardAudit.instance_variable_set(:@configuration, nil)
      StandardAudit.configure { |c| c.subscribe_to "audit.event.**" }

      Rails.event.notify("audit.event.created", actor: user)
      Rails.event.notify("audit.event.nested.deep", actor: user)

      expect(StandardAudit::AuditLog.count).to eq(2)
    end

    it "accepts Regexp patterns" do
      StandardAudit.instance_variable_set(:@configuration, nil)
      StandardAudit.configure { |c| c.subscribe_to(/\Abilling\./) }

      Rails.event.notify("billing.invoice.paid", actor: user)
      Rails.event.notify("other.thing", actor: user)

      expect(StandardAudit::AuditLog.pluck(:event_type)).to eq(["billing.invoice.paid"])
    end
  end
end
