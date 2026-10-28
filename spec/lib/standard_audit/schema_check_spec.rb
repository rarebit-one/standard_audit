require "rails_helper"

RSpec.describe StandardAudit::SchemaCheck do
  let(:model) { StandardAudit::AuditLog }
  let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }

  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
    described_class.reset!
    allow(Rails).to receive(:logger).and_return(logger)
  end

  after do
    StandardAudit.instance_variable_set(:@configuration, nil)
    described_class.reset!
  end

  # An audit_logs table as it stands in a host that installed before 0.13 and
  # never ran `standard_audit:add_previous_checksum`.
  def simulate_unupgraded_table
    columns = model.column_names - ["previous_checksum"]
    upgrade = [%w[previous_checksum], %w[created_at id], %w[checksum]]
    indexes = model.connection.indexes(model.table_name).reject { |index| upgrade.include?(Array(index.columns)) }

    allow(model).to receive(:column_names).and_return(columns)
    allow(model.connection).to receive(:indexes).and_call_original
    allow(model.connection).to receive(:indexes).with(model.table_name).and_return(indexes)
  end

  it "finds nothing missing on an up-to-date table" do
    expect(described_class.missing).to eq([])

    StandardAudit.record("schema.current")

    expect(logger).not_to have_received(:warn)
  end

  context "when the upgrade migration was never run" do
    before { simulate_unupgraded_table }

    it "names each missing piece" do
      expect(described_class.missing).to eq([
        "the previous_checksum column",
        "the [created_at, id] index",
        "the checksum index"
      ])
    end

    it "warns once per process with the generator to run, and still writes" do
      expect {
        StandardAudit.record("schema.first")
        StandardAudit.record("schema.second")
      }.to change(model, :count).by(2)

      expect(logger).to have_received(:warn).once.with(
        a_string_including("previous_checksum column", "standard_audit:add_previous_checksum")
      )
    end

    it "introspects the table once, not per write" do
      3.times { |i| StandardAudit.record("schema.cached.#{i}") }

      expect(model.connection).to have_received(:indexes).with(model.table_name).once
    end

    it "warns from the batch path too" do
      StandardAudit.batch { StandardAudit.record("schema.batched") }

      expect(logger).to have_received(:warn).once.with(a_string_including("standard_audit:add_previous_checksum"))
    end

    it "raises on every write when config.schema_check = :raise" do
      StandardAudit.config.schema_check = :raise

      2.times do
        expect { model.create!(event_type: "schema.raise", occurred_at: Time.current) }
          .to raise_error(StandardAudit::MissingUpgradeMigration, /add_previous_checksum/)
      end
      expect(model.where(event_type: "schema.raise")).to be_empty
    end

    it "skips the check when config.schema_check = false" do
      StandardAudit.config.schema_check = false

      StandardAudit.record("schema.off")

      expect(model.connection).not_to have_received(:indexes).with(model.table_name)
      expect(logger).not_to have_received(:warn)
    end
  end

  it "does not cache a failed introspection" do
    allow(model.connection).to receive(:indexes).and_call_original
    allow(model.connection).to receive(:indexes).with(model.table_name)
      .and_raise(ActiveRecord::ConnectionNotEstablished)

    expect(described_class.missing).to eq([])
    expect(described_class.missing).to eq([])
    expect(model.connection).to have_received(:indexes).with(model.table_name).twice
  end

  it "defaults config.schema_check to :warn" do
    expect(StandardAudit::Configuration.new.schema_check).to eq(:warn)
  end
end

RSpec.describe StandardAudit::Checks::Schema do
  subject(:check) { described_class.new(name: :audit_schema, critical: false) }

  after { StandardAudit::SchemaCheck.reset! }

  it "is ok on an up-to-date table" do
    StandardAudit::SchemaCheck.reset!

    expect(check.run).to eq(status: :ok)
  end

  it "warns with the missing pieces and the generator command" do
    StandardAudit::SchemaCheck.reset!
    allow(StandardAudit::SchemaCheck).to receive(:missing).and_return(["the previous_checksum column"])

    result = check.run

    expect(result[:status]).to eq(:warn)
    expect(result[:missing]).to eq(["the previous_checksum column"])
    expect(result[:message]).to include("standard_audit:add_previous_checksum")
  end
end
