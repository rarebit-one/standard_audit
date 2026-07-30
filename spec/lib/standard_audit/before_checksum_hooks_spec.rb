require "rails_helper"

RSpec.describe "before_checksum hooks" do
  before do
    StandardAudit.clear_baseline_configuration!
    StandardAudit.reset_configuration!
  end

  after do
    StandardAudit.clear_baseline_configuration!
    StandardAudit.reset_configuration!
  end

  let(:organisation) { Organisation.create!(name: "Acme") }

  def write(event_type: "audit.hook.test", **attrs)
    StandardAudit::AuditLog.create!(event_type: event_type, occurred_at: Time.current, **attrs)
  end

  it "defaults to no hooks" do
    expect(StandardAudit.config.before_checksum_hooks).to eq([])
  end

  it "runs a registered block with the record" do
    seen = []
    StandardAudit.config.before_checksum { |log| seen << log.event_type }

    write

    expect(seen).to eq(["audit.hook.test"])
  end

  it "runs hooks in registration order" do
    order = []
    StandardAudit.config.before_checksum { order << :first }
    StandardAudit.config.before_checksum { order << :second }

    write

    expect(order).to eq(%i[first second])
  end

  it "accepts a Symbol naming an AuditLog instance method" do
    # This is the shape a host concern mixed into AuditLog needs.
    StandardAudit.config.before_checksum :event_type
    expect { write }.not_to raise_error
  end

  it "raises when given neither a callable nor a block" do
    expect { StandardAudit.config.before_checksum }
      .to raise_error(ArgumentError, /needs a callable/)
  end

  it "sees the assigned UUID, because it runs after assign_uuid" do
    ids = []
    StandardAudit.config.before_checksum { |log| ids << log.id }

    log = write

    expect(ids).to eq([log.id])
    expect(ids.first).to be_present
  end

  describe "the regression that prepend: true was buying" do
    it "produces a verifiable row when a hook sets a CHECKSUM_FIELDS member" do
      # scope_gid / scope_type are members of CHECKSUM_FIELDS. A host callback
      # registered as a plain `before_create` would run AFTER the gem's
      # compute_checksum, so the digest would cover the pre-backfill value and
      # verify_chain would flag every backfilled row. Hosts worked around it
      # with `prepend: true`; registering here removes the need.
      org = organisation
      StandardAudit.config.before_checksum { |log| log.scope = org if log.scope_gid.blank? }

      log = write

      expect(log.scope_gid).to eq(org.to_global_id.to_s)
      expect(log.scope_type).to eq("Organisation")
      expect(StandardAudit::AuditLog.verify_chain).to include(valid: true, failures: [])
    end

    it "keeps the chain verifiable across several hooked rows" do
      org = organisation
      StandardAudit.config.before_checksum { |log| log.scope = org }

      3.times { |i| write(event_type: "audit.hook.#{i}") }

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:verified]).to eq(3)
      expect(result[:valid]).to be(true)
    end

    it "also covers a hook that rewrites metadata" do
      StandardAudit.config.before_checksum { |log| log.metadata = log.metadata.merge("derived" => true) }

      log = write(metadata: { "a" => 1 })

      expect(log.metadata).to eq("a" => 1, "derived" => true)
      expect(StandardAudit::AuditLog.verify_chain[:valid]).to be(true)
    end
  end

  describe "failure isolation" do
    it "never fails the audit write" do
      StandardAudit.config.before_checksum { raise "boom" }
      allow(Rails.logger).to receive(:warn)

      expect { write }.to change(StandardAudit::AuditLog, :count).by(1)
      expect(Rails.logger).to have_received(:warn).with(/before_checksum hook failed: RuntimeError: boom/)
    end

    it "still runs the remaining hooks after one raises" do
      ran = []
      StandardAudit.config.before_checksum { raise "boom" }
      StandardAudit.config.before_checksum { ran << :second }
      allow(Rails.logger).to receive(:warn)

      write

      expect(ran).to eq([:second])
    end

    it "rolls back attributes a hook mutated before it raised" do
      # Otherwise the hook is not really 'skipped': the half-applied state gets
      # checksummed and persisted by the callbacks that follow.
      org = organisation
      StandardAudit.config.before_checksum do |log|
        log.scope = org
        raise "lookup failed after partial assignment"
      end
      allow(Rails.logger).to receive(:warn)

      log = write

      expect(log.scope_gid).to be_nil
      expect(log.scope_type).to be_nil
      expect(log.scope).to be_nil
      expect(StandardAudit::AuditLog.find(log.id).scope_gid).to be_nil
      expect(StandardAudit::AuditLog.verify_chain[:valid]).to be(true)
    end

    it "keeps the mutations of hooks that succeeded around a failing one" do
      org = organisation
      StandardAudit.config.before_checksum { |log| log.scope = org }
      StandardAudit.config.before_checksum do |log|
        log.request_id = "half-applied"
        raise "boom"
      end
      allow(Rails.logger).to receive(:warn)

      log = write

      expect(log.scope_gid).to eq(org.to_global_id.to_s)
      expect(log.request_id).to be_nil
      expect(StandardAudit::AuditLog.verify_chain[:valid]).to be(true)
    end

    it "leaves a row a failing hook did not touch fully verifiable" do
      StandardAudit.config.before_checksum { raise "boom" }
      allow(Rails.logger).to receive(:warn)

      write

      expect(StandardAudit::AuditLog.verify_chain[:valid]).to be(true)
    end
  end

  describe "a row created with an explicit checksum" do
    it "re-derives the checksum when a hook changed a checksummed field" do
      # compute_checksum is skipped when a checksum is supplied, so without
      # this the row would persist a digest that no longer describes it and
      # fail verify_chain immediately.
      org = organisation
      StandardAudit.config.before_checksum { |log| log.scope = org }

      log = StandardAudit::AuditLog.new(event_type: "audit.hook.presum", occurred_at: Time.current)
      log.checksum = log.compute_checksum_value
      supplied = log.checksum
      log.save!

      expect(log.scope_gid).to eq(org.to_global_id.to_s)
      expect(log.checksum).not_to eq(supplied)
      expect(StandardAudit::AuditLog.verify_chain[:valid]).to be(true)
    end

    it "keeps the supplied checksum when hooks touched nothing checksummed" do
      # actor_role-style derived columns are not in CHECKSUM_FIELDS, so hooks
      # still run for pre-checksummed rows without invalidating the digest.
      StandardAudit.config.before_checksum { |log| log.event_type }

      log = StandardAudit::AuditLog.new(event_type: "audit.hook.presum2", occurred_at: Time.current)
      log.checksum = log.compute_checksum_value
      supplied = log.checksum
      log.save!

      expect(log.checksum).to eq(supplied)
    end
  end

  it "does not run on the batched write path, which never instantiates a model" do
    ran = []
    StandardAudit.config.before_checksum { ran << :hook }

    StandardAudit.batch { StandardAudit.record("audit.hook.batched") }

    expect(StandardAudit::AuditLog.count).to eq(1)
    expect(ran).to be_empty
  end

  it "runs on the StandardAudit.record path" do
    ran = []
    StandardAudit.config.before_checksum { ran << :hook }

    StandardAudit.record("audit.hook.record")

    expect(ran).to eq([:hook])
  end

  it "runs on the AS::Notifications subscriber path" do
    subscriber = nil
    ran = []
    StandardAudit.config.before_checksum { ran << :hook }
    StandardAudit.config.subscribe_to "audit.hook.subscriber"
    subscriber = StandardAudit::Subscriber.new
    subscriber.setup!

    ActiveSupport::Notifications.instrument("audit.hook.subscriber", {})

    expect(ran).to eq([:hook])
  ensure
    subscriber&.teardown!
  end
end
