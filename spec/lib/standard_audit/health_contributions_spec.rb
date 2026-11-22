require "rails_helper"

# standard_health is not in this bundle (and must never be a dependency), so
# these specs fire the load hook with a fake that records what a real
# StandardHealth::Contributions registry would receive.
RSpec.describe "standard_health contributions" do
  let(:health) do
    Class.new do
      attr_reader :checks, :env_vars

      def initialize
        @checks = []
        @env_vars = {}
      end

      def contribute_check(name, klass, critical: false, timeout: nil, **options)
        @checks << { name: name, klass: klass, critical: critical, timeout: timeout, options: options }
      end

      def contribute_env_vars(contributor, &block)
        recorder = Class.new do
          attr_reader :entries

          def initialize
            @entries = []
          end

          %i[required recommended forbidden].each do |level|
            define_method(level) { |name, **options| @entries << { level: level, name: name, **options } }
          end
        end.new
        recorder.instance_eval(&block)
        @env_vars[contributor] = recorder.entries
      end
    end.new
  end

  before { ActiveSupport.run_load_hooks(:standard_health, health) }

  it "contributes the retention check under the name standard_health dedupes on, non-critical" do
    expect(health.checks).to include(
      name: :audit_retention, klass: "StandardAudit::Checks::Retention", critical: false, timeout: nil, options: {}
    )
  end

  it "contributes the schema check, non-critical" do
    expect(health.checks).to include(
      name: :audit_schema, klass: "StandardAudit::Checks::Schema", critical: false, timeout: nil, options: {}
    )
  end

  it "names each check by its class's default name" do
    health.checks.each do |check|
      expect(check[:klass].constantize.new.instance_variable_get(:@name)).to eq(check[:name])
    end
  end

  it "passes classes as Strings, so they resolve lazily" do
    expect(health.checks.map { |c| c[:klass] }).to all(be_a(String))
  end

  it "declares STANDARD_AUDIT_RETENTION_DAYS as recommended, describing both accepted values" do
    entry = health.env_vars.fetch("standard_audit").find { |e| e[:name] == :STANDARD_AUDIT_RETENTION_DAYS }

    expect(entry).to include(level: :recommended)
    expect(entry[:description]).to include("positive integer", "indefinite")
  end

  it "declares no env var outside the gem's own namespace" do
    names = health.env_vars.values.flatten.map { |e| e[:name].to_s }

    expect(names).to all(start_with("STANDARD_AUDIT_"))
  end
end
