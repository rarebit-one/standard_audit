require "rails_helper"

# Every way a row can be written must go through one path, so that
# `current_scope_resolver`, `metadata_builder` and `before_write` apply
# uniformly. Each example below drives one entry point and asserts the same
# three effects on the row that lands.
RSpec.describe "StandardAudit single write path" do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:order) { Order.create!(total: 10) }
  let(:tenant) { Organisation.create!(name: "Tenant") }
  let(:explicit_scope) { Organisation.create!(name: "Explicit") }
  let(:seen) { [] }
  let(:notifications_subscriber) { StandardAudit::Subscriber.new }

  before do
    tenant_org = tenant
    captured = seen

    StandardAudit.reset_configuration!(replay_baseline: false)
    StandardAudit.configure do |config|
      config.subscribe_to(/\Awrite_path\./)
      config.current_scope_resolver = -> { tenant_org }
      config.metadata_builder = ->(metadata) { metadata.merge("engine_scope" => "admin") }
      config.before_write = ->(entry) {
        captured << entry[:event_type]
        entry[:metadata] = entry[:metadata].merge("surface" => "mcp")
      }
    end

    notifications_subscriber.setup!
  end

  after do
    notifications_subscriber.teardown!
    StandardAudit.reset_configuration!(replay_baseline: false)
  end

  # The engine subscribes StandardAudit.event_subscriber to Rails.event at
  # boot; swap in a private one so each event is written exactly once.
  def with_private_event_subscriber
    Rails.event.subscribers.each { |s| Rails.event.unsubscribe(s[:subscriber]) }
    event_subscriber = StandardAudit::EventSubscriber.new
    Rails.event.subscribe(event_subscriber)
    yield
  ensure
    Rails.event.unsubscribe(event_subscriber) if event_subscriber
    Rails.event.subscribe(StandardAudit.event_subscriber)
  end

  def expect_uniform_row(event_type, scope: tenant)
    log = StandardAudit::AuditLog.where(event_type: event_type).sole
    expect(log.scope).to eq(scope)
    expect(log.metadata).to include("engine_scope" => "admin", "surface" => "mcp")
    expect(seen).to eq([event_type])
    log
  end

  it "applies on a direct StandardAudit.record" do
    StandardAudit.record("write_path.direct", actor: user, target: order)

    expect_uniform_row("write_path.direct")
  end

  it "applies on Auditable#record_audit" do
    user.record_audit("write_path.auditable", target: order)

    expect(expect_uniform_row("write_path.auditable").actor).to eq(user)
  end

  it "applies on Operation#audit!" do
    Orders::CreateOperation.new(order).execute

    log = expect_uniform_row("order.created")
    expect(log.metadata).to include("total" => 100)
  end

  it "applies on the ActiveSupport::Notifications subscriber" do
    ActiveSupport::Notifications.instrument("write_path.notification", actor: user, target: order, note: "hi")

    log = expect_uniform_row("write_path.notification")
    expect(log.metadata).to include("note" => "hi")
    expect(log.actor).to eq(user)
  end

  it "applies on the block form" do
    StandardAudit.record("write_path.block", actor: user, target: order) { :done }

    expect_uniform_row("write_path.block")
  end

  it "applies on the Rails.event subscriber", skip: !Rails.respond_to?(:event) do
    with_private_event_subscriber do
      Rails.event.notify("write_path.rails_event", actor: user, target: order)
    end

    log = expect_uniform_row("write_path.rails_event")
    expect(log.metadata).to have_key("_source")
  end

  it "applies on the async path" do
    StandardAudit.config.async = true
    expect(StandardAudit::CreateAuditLogJob).to receive(:perform_later).with(
      hash_including(
        "event_type" => "write_path.async",
        "scope_gid" => tenant.to_global_id.to_s,
        "metadata" => hash_including("engine_scope" => "admin", "surface" => "mcp")
      )
    )

    StandardAudit.record("write_path.async", actor: user)
    expect(seen).to eq(["write_path.async"])
  end

  it "applies on the batched path" do
    StandardAudit.batch { StandardAudit.record("write_path.batched", actor: user) }

    expect_uniform_row("write_path.batched")
  end

  it "buffers notification-subscriber writes inside a batch like every other write" do
    StandardAudit.batch do
      ActiveSupport::Notifications.instrument("write_path.in_batch", actor: user)
      expect(StandardAudit::AuditLog.where(event_type: "write_path.in_batch")).to be_empty
    end

    expect_uniform_row("write_path.in_batch")
  end

  describe "current_scope_resolver" do
    it "never overrides an explicit scope" do
      StandardAudit.record("write_path.explicit", actor: user, scope: explicit_scope)

      expect_uniform_row("write_path.explicit", scope: explicit_scope)
    end

    it "never overrides a scope the scope_extractor found in a payload" do
      ActiveSupport::Notifications.instrument("write_path.payload_scope", scope: explicit_scope)

      expect_uniform_row("write_path.payload_scope", scope: explicit_scope)
    end

    it "leaves the row unscoped when unset and nothing is given" do
      StandardAudit.config.current_scope_resolver = nil
      StandardAudit.record("write_path.unscoped")

      expect(StandardAudit::AuditLog.last.scope_gid).to be_nil
    end
  end

  describe "before_write" do
    it "sees the resolved actor, scope and request context" do
      entries = []
      StandardAudit.config.before_write = ->(entry) { entries << entry.dup }

      StandardAudit.record("write_path.inspect", actor: user, request_id: "req-1")

      expect(entries.sole).to include(
        event_type: "write_path.inspect", actor: user, scope: tenant, request_id: "req-1"
      )
    end

    it "runs before redaction, so a sensitive key it injects is still stripped" do
      StandardAudit.config.before_write = ->(entry) { entry[:metadata] = entry[:metadata].merge(password: "x") }

      StandardAudit.record("write_path.redacted", actor: user)

      expect(StandardAudit::AuditLog.last.metadata).not_to have_key("password")
    end

    it "aborts a direct write when it raises" do
      StandardAudit.config.before_write = ->(_entry) { raise ArgumentError, "PII in metadata" }

      expect { StandardAudit.record("write_path.rejected", actor: user) }.to raise_error(ArgumentError, "PII in metadata")
      expect(StandardAudit::AuditLog.where(event_type: "write_path.rejected")).to be_empty
    end

    it "is rescued and reported on the subscriber path" do
      StandardAudit.config.before_write = ->(_entry) { raise ArgumentError, "PII in metadata" }
      allow(Rails.error).to receive(:report)

      expect { ActiveSupport::Notifications.instrument("write_path.sub_rejected", actor: user) }.not_to raise_error
      expect(Rails.error).to have_received(:report).with(
        an_instance_of(ArgumentError),
        hash_including(handled: true, context: hash_including(audit_action: "write_path.sub_rejected"))
      )
    end

    describe "entry[:via]" do
      let(:vias) { {} }

      before do
        captured = vias
        StandardAudit.config.before_write = ->(entry) { captured[entry[:event_type]] = entry[:via] }
      end

      it "is :direct for StandardAudit.record, Auditable#record_audit and Operation#audit!" do
        StandardAudit.record("write_path.via_direct", actor: user)
        user.record_audit("write_path.via_auditable", target: order)
        Orders::CreateOperation.new(order).execute

        expect(vias).to eq(
          "write_path.via_direct" => :direct, "write_path.via_auditable" => :direct, "order.created" => :direct
        )
      end

      it "is :notification for the ActiveSupport::Notifications subscriber, block form included" do
        ActiveSupport::Notifications.instrument("write_path.via_notification", actor: user)
        StandardAudit.record("write_path.via_block", actor: user) { :done }

        expect(vias).to eq("write_path.via_notification" => :notification, "write_path.via_block" => :notification)
      end

      it "is :rails_event for the Rails.event subscriber", skip: !Rails.respond_to?(:event) do
        with_private_event_subscriber { Rails.event.notify("write_path.via_rails_event", actor: user) }

        expect(vias).to eq("write_path.via_rails_event" => :rails_event)
      end

      it "is not persisted" do
        StandardAudit.record("write_path.via_persisted", actor: user)

        log = StandardAudit::AuditLog.where(event_type: "write_path.via_persisted").sole
        expect(log.metadata).not_to have_key("via")
      end
    end

    it "runs after metadata_builder and sees its output" do
      StandardAudit.config.metadata_builder = ->(metadata) { metadata.merge("email" => "a***@example.com") }
      seen_metadata = nil
      StandardAudit.config.before_write = ->(entry) { seen_metadata = entry[:metadata].dup }

      StandardAudit.record("write_path.order", actor: user, metadata: { "email" => "alice@example.com" })

      expect(seen_metadata).to include("email" => "a***@example.com")
    end

    it "may rewrite the scope" do
      other = explicit_scope
      StandardAudit.config.before_write = ->(entry) { entry[:scope] = other }

      StandardAudit.record("write_path.rescoped", actor: user)

      expect(StandardAudit::AuditLog.last.scope).to eq(other)
    end
  end

  describe "metadata_builder" do
    it "does not see the Rails.event reserved keys", skip: !Rails.respond_to?(:event) do
      keys_seen = []
      StandardAudit.config.metadata_builder = ->(metadata) { keys_seen.concat(metadata.keys.map(&:to_s)) and metadata }
      with_private_event_subscriber do
        Rails.event.tagged(team: "a") { Rails.event.notify("write_path.tags", actor: user, note: 1) }
      end

      expect(keys_seen).to eq(["note"])
      expect(StandardAudit::AuditLog.last.metadata).to include("_tags", "_source")
    end
  end
end
