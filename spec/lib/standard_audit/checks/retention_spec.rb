require "rails_helper"

RSpec.describe StandardAudit::Checks::Retention do
  subject(:check) { described_class.new(name: :audit_retention, critical: false) }

  around do |example|
    original_app_env = ENV["APP_ENVIRONMENT"]
    original_retention = StandardAudit.config.retention_days
    example.run
  ensure
    if original_app_env.nil?
      ENV.delete("APP_ENVIRONMENT")
    else
      ENV["APP_ENVIRONMENT"] = original_app_env
    end
    StandardAudit.config.retention_days = original_retention
  end

  def run_with(app_environment:, retention_days:)
    if app_environment.nil?
      ENV.delete("APP_ENVIRONMENT")
    else
      ENV["APP_ENVIRONMENT"] = app_environment
    end
    StandardAudit.config.retention_days = retention_days
    check.run
  end

  it "conforms to the StandardHealth check contract (name:/critical:/#run)" do
    expect(described_class.instance_method(:run).arity).to eq(0)
    expect { described_class.new(name: :x, critical: false) }.not_to raise_error
  end

  context "on a production deployment (APP_ENVIRONMENT=production)" do
    it "warns when retention is unbounded" do
      result = run_with(app_environment: "production", retention_days: nil)

      expect(result[:status]).to eq(:warn)
      expect(result[:message]).to include("unbounded")
      expect(result[:message]).to include("STANDARD_AUDIT_RETENTION_DAYS")
    end

    it "is ok, and says so, when retention is deliberately :indefinite" do
      result = run_with(app_environment: "production", retention_days: :indefinite)

      expect(result[:status]).to eq(:ok)
      expect(result[:retention]).to eq("indefinite")
    end

    it "is ok when retention is configured" do
      result = run_with(app_environment: "production", retention_days: 365)

      expect(result[:status]).to eq(:ok)
      expect(result[:retention_days]).to eq(365)
    end
  end

  context "on staging (APP_ENVIRONMENT=staging, still RAILS_ENV=production)" do
    it "does not warn even when retention is unbounded" do
      result = run_with(app_environment: "staging", retention_days: nil)

      expect(result[:status]).to eq(:ok)
    end
  end

  context "on other non-production deployments" do
    %w[preview development test].each do |name|
      it "does not warn for APP_ENVIRONMENT=#{name}" do
        expect(run_with(app_environment: name, retention_days: nil)[:status]).to eq(:ok)
      end
    end
  end

  # Fails closed: a misspelt APP_ENVIRONMENT on a production box must not
  # silence the advisory.
  context "when APP_ENVIRONMENT is unrecognised" do
    it "treats it as production and warns" do
      expect(run_with(app_environment: "prod", retention_days: nil)[:status]).to eq(:warn)
    end
  end

  context "when APP_ENVIRONMENT has the wrong case or extra whitespace" do
    it "fails closed on a capitalised name" do
      expect(run_with(app_environment: "Staging", retention_days: nil)[:status]).to eq(:warn)
    end

    it "ignores surrounding whitespace" do
      expect(run_with(app_environment: " staging ", retention_days: nil)[:status]).to eq(:ok)
    end

    it "treats a blank value as unset" do
      expect(run_with(app_environment: "  ", retention_days: nil)[:status]).to eq(:ok)
    end
  end

  context "when APP_ENVIRONMENT is unset" do
    it "falls back to Rails.env and does not warn in the test environment" do
      result = run_with(app_environment: nil, retention_days: nil)

      expect(result[:status]).to eq(:ok)
    end
  end
end
