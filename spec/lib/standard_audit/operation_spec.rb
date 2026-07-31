require "rails_helper"

RSpec.describe StandardAudit::Operation do
  before { StandardAudit.reset_configuration! }
  after { StandardAudit.reset_configuration! }

  # Anonymous classes: they exercise the DSL without polluting
  # `Audit.operations`, which excludes unnamed classes by design.
  def operation_class(name = "AnonymousOperation", &body)
    Class.new do
      include StandardAudit::Operation

      define_singleton_method(:name) { name }
      class_exec(&body) if body
    end
  end

  def run(klass, action, **attrs)
    klass.new.send(:audit!, action, **attrs)
  end

  describe "declarations" do
    it "records `audits` as an Array of Strings" do
      klass = operation_class { audits :"order.created", "order.exported" }

      expect(klass.audit_spec).to eq(%w[order.created order.exported])
    end

    it "flattens an Array argument, so a catalogue slice can be splatted in" do
      klass = operation_class { audits %w[order.created order.exported] }

      expect(klass.audit_spec).to eq(%w[order.created order.exported])
    end

    it "rejects an empty declaration rather than silently meaning `none`" do
      expect { operation_class { audits } }.to raise_error(ArgumentError, /at least one action/)
    end

    it "records `audit_none!` as :none" do
      expect(operation_class { audit_none! }.audit_spec).to eq(:none)
    end

    it "records `audit_abstract!` as :abstract" do
      expect(operation_class { audit_abstract! }.audit_spec).to eq(:abstract)
    end

    it "defaults to nil so an undeclared operation is detectable" do
      expect(operation_class.audit_spec).to be_nil
    end

    # The single most load-bearing detail of the whole DSL: @audit_spec is a
    # CLASS-level ivar, deliberately not inherited. A leaf that inherited its
    # parent's declaration would pass the meta-spec while writing nothing, or
    # while writing an action it never stated.
    it "does not inherit the parent's declaration" do
      parent = operation_class("ParentOperation") { audits "order.created" }
      child = Class.new(parent) { def self.name = "ChildOperation" }

      expect(child.audit_spec).to be_nil
    end
  end

  describe "#audit! when the declaration matches" do
    let(:order) { Order.create!(total: 10) }

    it "writes the row through StandardAudit.record" do
      klass = operation_class { audits "order.created" }

      expect { run(klass, "order.created", target: order) }
        .to change { StandardAudit::AuditLog.where(event_type: "order.created").count }.by(1)
    end

    it "accepts a Symbol action" do
      klass = operation_class { audits "order.created" }

      expect { run(klass, :"order.created", target: order) }
        .to change(StandardAudit::AuditLog, :count).by(1)
    end

    it "forwards actor/target/metadata straight through" do
      klass = operation_class { audits "order.created" }
      user = User.create!(email: "a@example.com")

      run(klass, "order.created", actor: user, target: order, metadata: { total: 5 })
      log = StandardAudit::AuditLog.last

      expect(log.actor_gid).to eq(user.to_gid.to_s)
      expect(log.target_gid).to eq(order.to_gid.to_s)
      expect(log.metadata["total"]).to eq(5)
    end
  end

  describe "#audit! declaration drift" do
    it "raises when the class declared nothing" do
      klass = operation_class("UndeclaredOperation")

      expect { run(klass, "order.created") }
        .to raise_error(described_class::DeclarationError, /declares neither/)
    end

    it "raises when the class declared `audit_none!`" do
      klass = operation_class { audit_none! }

      expect { run(klass, "order.created") }
        .to raise_error(described_class::DeclarationError, /declares `audit_none!`/)
    end

    it "raises when the class declared `audit_abstract!`" do
      klass = operation_class { audit_abstract! }

      expect { run(klass, "order.created") }
        .to raise_error(described_class::DeclarationError, /declares `audit_abstract!`/)
    end

    it "raises when the action isn't the one declared" do
      klass = operation_class { audits "order.created" }

      expect { run(klass, "order.exported") }
        .to raise_error(described_class::DeclarationError, /not in its declared actions/)
    end

    it "writes nothing when it raises" do
      klass = operation_class { audit_none! }

      expect { run(klass, "order.created") rescue nil }
        .not_to change(StandardAudit::AuditLog, :count)
    end
  end

  describe "the catalogue check" do
    let(:klass) { operation_class { audits "order.created" } }

    it "is skipped entirely when no catalogue is configured" do
      expect(StandardAudit.config.audit_catalogue).to be_nil

      expect { run(klass, "order.created") }.to change(StandardAudit::AuditLog, :count).by(1)
    end

    it "raises when the action is absent from the catalogue" do
      StandardAudit.configure { |c| c.audit_catalogue = -> { %w[order.exported] } }

      expect { run(klass, "order.created") }
        .to raise_error(described_class::DeclarationError, /not in the configured audit catalogue/)
    end

    it "accepts a plain Array catalogue" do
      StandardAudit.configure { |c| c.audit_catalogue = %w[order.created] }

      expect { run(klass, "order.created") }.to change(StandardAudit::AuditLog, :count).by(1)
    end

    # Membership is the ONLY rule. One consumer's catalogue carries
    # notification-bus names verbatim, because the subscriber records the bus
    # name as-is; a dot-count, prefix, or case rule would reject them and
    # shortening them would orphan every historical row.
    it "applies no shape rule — a bus-namespaced action is fine" do
      bus_action = "jumpdrive-web.surface.audience_changed"
      StandardAudit.configure { |c| c.audit_catalogue = -> { [bus_action] } }
      bus_klass = operation_class { audits "jumpdrive-web.surface.audience_changed" }

      expect { run(bus_klass, bus_action) }.to change(StandardAudit::AuditLog, :count).by(1)
    end

    it "applies no case rule" do
      StandardAudit.configure { |c| c.audit_catalogue = -> { %w[Order.Created] } }
      odd = operation_class { audits "Order.Created" }

      expect { run(odd, "Order.Created") }.to change(StandardAudit::AuditLog, :count).by(1)
    end
  end

  describe "verification gating" do
    it "does not verify when `verify_audit_declarations` is false" do
      StandardAudit.configure { |c| c.verify_audit_declarations = false }
      klass = operation_class("UndeclaredOperation")

      # Production behaviour: an undeclared write still lands. A developer's
      # mistake must not 500 a user; the meta-spec is the gate.
      expect { run(klass, "order.created") }.to change(StandardAudit::AuditLog, :count).by(1)
    end

    it "accepts a callable" do
      StandardAudit.configure { |c| c.verify_audit_declarations = -> { true } }

      expect { run(operation_class("UndeclaredOperation"), "x") }
        .to raise_error(described_class::DeclarationError)
    end

    it "defaults to on in a local environment" do
      expect(StandardAudit::Operation::Audit.verify?).to be(true)
    end
  end

  describe "write-error policy" do
    let(:klass) { operation_class { audits "order.created" } }

    before do
      allow(StandardAudit).to receive(:record).and_raise(ActiveRecord::StatementInvalid, "boom")
    end

    it "reports and swallows by default" do
      expect(Rails.error).to receive(:report).with(
        instance_of(ActiveRecord::StatementInvalid),
        hash_including(handled: true)
      )

      expect(run(klass, "order.created")).to be_nil
    end

    # Four of the five apps swallow; one deliberately does not, because for it
    # an unaudited state change is itself a compliance failure. A
    # swallow-only module would have silently downgraded that posture.
    it "re-raises when `raise_on_audit_write_error` is true" do
      StandardAudit.configure { |c| c.raise_on_audit_write_error = true }

      expect { run(klass, "order.created") }.to raise_error(ActiveRecord::StatementInvalid, "boom")
    end

    it "routes through `audit_write_error_handler` when set" do
      seen = []
      StandardAudit.configure do |c|
        c.audit_write_error_handler = ->(error, action:, operation:) {
          seen << [error.class, action, operation.class]
        }
      end

      run(klass, "order.created")

      expect(seen).to eq([[ActiveRecord::StatementInvalid, "order.created", klass]])
    end

    it "still raises after the handler when both are configured" do
      StandardAudit.configure do |c|
        c.audit_write_error_handler = ->(_e, action:, operation:) { }
        c.raise_on_audit_write_error = true
      end

      expect { run(klass, "order.created") }.to raise_error(ActiveRecord::StatementInvalid)
    end

    # DeclarationError must never be governed by the write-error policy: it is
    # a developer mistake, and swallowing it would hide drift from CI.
    it "propagates DeclarationError even when writes are swallowed" do
      StandardAudit.configure do |c|
        c.raise_on_audit_write_error = false
        c.audit_write_error_handler = ->(_e, action:, operation:) { raise "handler must not see this" }
      end

      expect { run(operation_class("UndeclaredOperation"), "order.created") }
        .to raise_error(described_class::DeclarationError)
    end
  end

  describe "configuration lifecycle" do
    # Every new config field must be defaulted in `initialize`, or
    # `reset_configuration!` (which the rspec plugin runs before every example)
    # leaves it nil and the behaviour silently changes mid-suite.
    it "restores all four operation fields on reset" do
      StandardAudit.configure do |c|
        c.audit_catalogue = -> { %w[x] }
        c.raise_on_audit_write_error = true
        c.audit_write_error_handler = ->(_e, action:, operation:) { }
        c.verify_audit_declarations = false
      end

      StandardAudit.reset_configuration!
      config = StandardAudit.config

      expect(config.audit_catalogue).to be_nil
      expect(config.raise_on_audit_write_error).to be(false)
      expect(config.audit_write_error_handler).to be_nil
      expect(config.verify_audit_declarations).to respond_to(:call)
    end

    it "survives a baseline replay" do
      StandardAudit.configure(baseline: true) { |c| c.audit_catalogue = -> { %w[order.created] } }
      StandardAudit.reset_configuration!

      expect(StandardAudit::Operation::Audit.catalogue).to eq(%w[order.created])
    ensure
      StandardAudit.clear_baseline_configuration!
    end
  end
end
