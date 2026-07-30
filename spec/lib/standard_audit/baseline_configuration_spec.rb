require "rails_helper"

RSpec.describe "StandardAudit.configure(baseline:)" do
  before do
    StandardAudit.clear_baseline_configuration!
    StandardAudit.reset_configuration!
  end

  after do
    StandardAudit.clear_baseline_configuration!
    StandardAudit.reset_configuration!
  end

  it "applies the block, exactly like a plain configure" do
    StandardAudit.configure(baseline: true) { |c| c.queue_name = :audit }

    expect(StandardAudit.config.queue_name).to eq(:audit)
  end

  it "is not registered by a plain configure (0.6.0 behaviour)" do
    StandardAudit.configure { |c| c.queue_name = :audit }

    expect(StandardAudit.baseline_configured?).to be(false)

    StandardAudit.reset_configuration!

    expect(StandardAudit.config.queue_name).to eq(:default)
  end

  it "is replayed by reset_configuration!" do
    StandardAudit.configure(baseline: true) do |c|
      c.queue_name = :audit
      c.subscribe_to "myapp.**"
    end

    StandardAudit.reset_configuration!

    expect(StandardAudit.config.queue_name).to eq(:audit)
    expect(StandardAudit.config.subscriptions).to eq(["myapp.**"])
  end

  it "replays behaviour, not just data — this is why it is required" do
    # The failure mode it exists to prevent: `before_checksum_hooks` live in
    # Configuration, so a suite that installs the rspec plugin without a
    # baseline loses its write-time hooks after the first example, and every
    # spec that would have noticed passes vacuously.
    ran = []
    StandardAudit.configure(baseline: true) { |c| c.before_checksum { ran << :hook } }

    StandardAudit.reset_configuration!
    StandardAudit::AuditLog.create!(event_type: "audit.baseline.test", occurred_at: Time.current)

    expect(ran).to eq([:hook])
  end

  it "does not accumulate on repeated resets" do
    StandardAudit.configure(baseline: true) { |c| c.subscribe_to "myapp.**" }

    3.times { StandardAudit.reset_configuration! }

    expect(StandardAudit.config.subscriptions).to eq(["myapp.**"])
  end

  it "discards per-example mutations while keeping the baseline" do
    StandardAudit.configure(baseline: true) { |c| c.sensitive_keys = %i[password] }
    StandardAudit.config.sensitive_keys += %i[one_off]

    StandardAudit.reset_configuration!

    expect(StandardAudit.config.sensitive_keys).to eq(%i[password])
  end

  it "keeps the last baseline block when registered more than once" do
    StandardAudit.configure(baseline: true) { |c| c.queue_name = :first }
    StandardAudit.configure(baseline: true) { |c| c.queue_name = :second }

    StandardAudit.reset_configuration!

    expect(StandardAudit.config.queue_name).to eq(:second)
  end

  it "can be skipped for a genuinely pristine configuration" do
    StandardAudit.configure(baseline: true) { |c| c.queue_name = :audit }

    StandardAudit.reset_configuration!(replay_baseline: false)

    expect(StandardAudit.config.queue_name).to eq(:default)
  end

  it "is forgotten by clear_baseline_configuration!" do
    StandardAudit.configure(baseline: true) { |c| c.queue_name = :audit }
    StandardAudit.clear_baseline_configuration!
    StandardAudit.reset_configuration!

    expect(StandardAudit.baseline_configured?).to be(false)
    expect(StandardAudit.config.queue_name).to eq(:default)
  end

  it "returns the configuration and tolerates a blockless call" do
    expect(StandardAudit.configure).to be(StandardAudit.config)
  end
end
