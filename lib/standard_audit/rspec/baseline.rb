require "standard_audit"

# Shared example guarding the `configure(baseline: true)` contract: that the
# app's StandardAudit configuration survives `StandardAudit.reset_configuration!`
# (which `require "standard_audit/rspec"` runs before every example).
#
#   require "standard_audit/rspec/baseline"   # or "standard_audit/rspec"
#
#   RSpec.describe "StandardAudit configuration baseline" do
#     it_behaves_like "a standard_audit baseline",
#       subscriptions: [/\Astandard_id\./, /\Aauthorization\./],
#       settings: {
#         retention_days: 1826,
#         raise_on_audit_write_error: true,
#         filter_nested_metadata: true,
#         queue_name: :maintenance
#       },
#       catalogue: -> { AuditCatalogue::ACTIONS },
#       sensitive_keys: %i[source_payload],
#       sensitive_key_patterns: [/secret/i],
#       present: %i[metadata_builder before_write current_scope_resolver],
#       hooks: 2   # or %i[backfill_scope classify_actor]
#   end
#
# Every option is optional. Behaviour held in lambdas (resolvers, builders)
# can't be compared by value, so list them under `present:` to assert they
# survive a reset, and keep an app-specific example for what they return.
#
# `hooks:` covers `before_checksum` hooks, which live in a list rather than a
# named setting. Pass an Integer to assert exactly that many are registered,
# or an Array of the Symbol hook names (`config.before_checksum :name`) to
# assert each is registered. The mutation example also clears the hooks
# before the reset, so it fails if the baseline block doesn't re-add them.
RSpec.shared_examples "a standard_audit baseline" do |options = {}|
  subscriptions          = Array(options[:subscriptions])
  settings               = options.fetch(:settings, {})
  catalogue              = options[:catalogue]
  sensitive_keys         = Array(options[:sensitive_keys])
  sensitive_key_patterns = Array(options[:sensitive_key_patterns])
  present                = Array(options[:present])
  hooks                  = options[:hooks]

  unless hooks.nil? || hooks.is_a?(Integer) || (hooks.is_a?(Array) && hooks.all? { |h| h.is_a?(Symbol) || h.is_a?(String) })
    raise ArgumentError, "hooks: must be an Integer (hook count) or an Array of Symbol hook names; got #{hooks.inspect}"
  end

  def standard_audit_baseline_assertions(subscriptions:, settings:, catalogue:, sensitive_keys:,
    sensitive_key_patterns:, present:, hooks:)
    config = StandardAudit.config

    expect(config.subscriptions).to include(*subscriptions) if subscriptions.any?
    settings.each do |name, value|
      expect(config.public_send(name)).to eq(value), "expected config.#{name} to be #{value.inspect} after a reset"
    end
    if catalogue
      resolved = config.audit_catalogue.respond_to?(:call) ? config.audit_catalogue.call : config.audit_catalogue
      expect(Array(resolved).map(&:to_s)).to match_array(Array(catalogue.call).map(&:to_s))
    end
    expect(config.sensitive_keys).to include(*sensitive_keys) if sensitive_keys.any?
    expect(config.sensitive_key_patterns).to include(*sensitive_key_patterns) if sensitive_key_patterns.any?
    present.each do |name|
      expect(config.public_send(name)).not_to be_nil, "expected config.#{name} to survive a reset"
    end
    case hooks
    when Integer
      expect(config.before_checksum_hooks.size).to eq(hooks),
        "expected #{hooks} before_checksum hook(s) after a reset, found #{config.before_checksum_hooks.size}"
    when Array
      registered = config.before_checksum_hooks.select { |h| h.is_a?(Symbol) || h.is_a?(String) }.map(&:to_sym)
      hooks.map(&:to_sym).each do |name|
        expect(registered).to include(name), "expected before_checksum :#{name} to survive a reset"
      end
    end
  end

  let(:standard_audit_baseline_options) do
    { subscriptions: subscriptions, settings: settings, catalogue: catalogue,
      sensitive_keys: sensitive_keys, sensitive_key_patterns: sensitive_key_patterns, present: present,
      hooks: hooks }
  end

  it "is registered with configure(baseline: true)" do
    expect(StandardAudit.baseline_configured?).to be(true),
      "config/initializers/standard_audit.rb must call StandardAudit.configure(baseline: true), " \
      "or reset_configuration! silently reverts every example to gem defaults"
  end

  it "carries the app's configuration" do
    standard_audit_baseline_assertions(**standard_audit_baseline_options)
  end

  it "restores it after a mutation and a reset" do
    StandardAudit.config.sensitive_keys += %i[standard_audit_isolation_canary]
    StandardAudit.config.subscribe_to "standard_audit.isolation_canary"
    settings.each_key { |name| StandardAudit.config.public_send(:"#{name}=", nil) }
    present.each { |name| StandardAudit.config.public_send(:"#{name}=", nil) }
    StandardAudit.config.before_checksum_hooks = [] unless hooks.nil?

    StandardAudit.reset_configuration!

    expect(StandardAudit.config.sensitive_keys).not_to include(:standard_audit_isolation_canary)
    expect(StandardAudit.config.subscriptions).not_to include("standard_audit.isolation_canary")
    standard_audit_baseline_assertions(**standard_audit_baseline_options)
  end
end
