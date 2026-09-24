require "rails_helper"
require "standard_audit/rspec/baseline"

RSpec.describe "a standard_audit baseline (shared example)" do
  before do
    StandardAudit.clear_baseline_configuration!
    StandardAudit.reset_configuration!
    StandardAudit.configure(baseline: true) do |config|
      config.subscribe_to(/\Astandard_id\./)
      config.retention_days = 1826
      config.raise_on_audit_write_error = true
      config.audit_catalogue = -> { %w[order.created] }
      config.sensitive_keys += %i[source_payload]
      config.sensitive_key_patterns = [/secret/i]
      config.before_write = ->(_entry) { }
      config.before_checksum :backfill_scope
      config.before_checksum { |_log| }
    end
  end

  after do
    StandardAudit.clear_baseline_configuration!
    StandardAudit.reset_configuration!
  end

  it_behaves_like "a standard_audit baseline",
    subscriptions: [/\Astandard_id\./],
    settings: { retention_days: 1826, raise_on_audit_write_error: true },
    catalogue: -> { %w[order.created] },
    sensitive_keys: %i[source_payload],
    sensitive_key_patterns: [/secret/i],
    present: %i[before_write],
    hooks: 2

  context "with hook names" do
    it_behaves_like "a standard_audit baseline", hooks: %i[backfill_scope]
  end

  # The shared example's own failure path: a baseline that loses a hook on
  # reset must fail the count assertion, not pass vacuously.
  it "notices a before_checksum hook that does not survive a reset" do
    StandardAudit.clear_baseline_configuration!
    StandardAudit.configure(baseline: true) { |config| config.before_checksum :backfill_scope }
    StandardAudit.config.before_checksum { |_log| } # added outside the baseline
    StandardAudit.reset_configuration!

    expect(StandardAudit.config.before_checksum_hooks.size).to eq(1)
  end

  it "fails when the configuration is not registered as a baseline" do
    StandardAudit.clear_baseline_configuration!
    StandardAudit.configure { |c| c.retention_days = 1826 }
    StandardAudit.reset_configuration!

    expect(StandardAudit.config.retention_days).not_to eq(1826)
    expect(StandardAudit.baseline_configured?).to be(false)
  end
end
