require "rails_helper"

RSpec.describe StandardAudit::SensitiveKeysDryRun do
  before { StandardAudit.reset_configuration! }
  after { StandardAudit.reset_configuration! }

  def write(metadata)
    StandardAudit::AuditLog.create!(
      event_type: "dry.run.test",
      occurred_at: Time.current,
      metadata: metadata
    )
  end

  it "reports nothing for an empty table" do
    report = described_class.call

    expect(report.rows_scanned).to eq(0)
    expect(report.stripped).to be_empty
    expect(report.kept).to be_empty
    expect(report.any_stripped?).to be(false)
  end

  it "counts, per key, what a candidate pattern would strip" do
    2.times { write("client_secret" => "sk", "order_id" => 1) }
    write("order_id" => 2)

    report = described_class.call(sensitive_key_patterns: [/secret/i])

    expect(report.rows_scanned).to eq(3)
    expect(report.stripped).to eq("client_secret" => 2)
    expect(report.kept).to eq("order_id" => 3)
    expect(report.any_stripped?).to be(true)
  end

  it "reports the current configuration when given no candidate" do
    write("password" => "x", "order_id" => 1)

    report = described_class.call

    expect(report.stripped).to eq("password" => 1)
  end

  it "reads keys in Ruby, so it works on the SQLite dummy (no jsonb_object_keys)" do
    # A guard against a future refactor reaching for a Postgres-only function:
    # the install template ships jsonb + GIN, but the gem must stay
    # backend-neutral.
    expect(StandardAudit::AuditLog.connection.adapter_name).to match(/sqlite/i)

    write("password" => "x")

    expect(described_class.call.stripped).to eq("password" => 1)
  end

  it "never writes anything" do
    write("password" => "x")
    before_rows = StandardAudit::AuditLog.pluck(:id, :metadata)

    described_class.call(sensitive_key_patterns: [/./])

    expect(StandardAudit::AuditLog.pluck(:id, :metadata)).to eq(before_rows)
  end

  it "honours sensitive_key_exceptions" do
    write("input_tokens" => 5, "access_token" => "x")

    report = described_class.call(
      sensitive_key_patterns: [/token/i],
      sensitive_key_exceptions: %i[input_tokens]
    )

    expect(report.stripped).to eq("access_token" => 1)
    expect(report.kept).to eq("input_tokens" => 1)
  end

  it "leaves reserved keys out of the stripped set no matter the rule" do
    write("_tags" => { "a" => 1 }, "_source" => "x.rb:1")

    report = described_class.call(sensitive_key_patterns: [/./])

    expect(report.stripped).to be_empty
    expect(report.kept.keys).to match_array(%w[_tags _source])
  end

  describe "nested keys" do
    before { write("stripe" => { "client_secret" => "sk", "id" => "ch_1" }) }

    it "surfaces a nested match as exposure when nested filtering is off" do
      report = described_class.call(sensitive_key_patterns: [/secret/i], nested: false)

      expect(report.stripped).to be_empty
      expect(report.nested_unfiltered).to eq("stripe.client_secret" => 1)
      expect(report.kept.keys).to include("stripe", "stripe.id")
    end

    it "counts it as stripped once nested filtering is on" do
      report = described_class.call(sensitive_key_patterns: [/secret/i], nested: true)

      expect(report.stripped).to eq("stripe.client_secret" => 1)
      expect(report.nested_unfiltered).to be_empty
    end

    it "paths through arrays" do
      write("charges" => [{ "password" => "x" }])

      report = described_class.call(nested: true)

      expect(report.stripped).to include("charges[].password" => 1)
    end

    it "counts a repeated path once per row, not once per occurrence" do
      # One row with two matching array elements is ONE affected row. The
      # counts are documented as row counts and drive an adoption decision, so
      # overstating them matters.
      write("charges" => [{ "password" => "a" }, { "password" => "b" }])

      report = described_class.call(nested: true)

      expect(report.stripped["charges[].password"]).to eq(1)
    end

    it "keeps a reserved subtree out of the report at any depth" do
      write("outer" => { "_tags" => { "password" => "kept" }, "password" => "gone" })

      report = described_class.call(nested: true)

      expect(report.stripped.keys).to include("outer.password")
      expect(report.stripped.keys).not_to include("outer._tags.password")
      expect(report.kept.keys).to include("outer._tags")
    end
  end

  it "accepts a scoped relation" do
    write("password" => "x")
    kept = write("order_id" => 1)

    report = described_class.call(relation: StandardAudit::AuditLog.where(id: kept.id))

    expect(report.rows_scanned).to eq(1)
    expect(report.stripped).to be_empty
  end

  describe "#to_s" do
    it "renders a readable report" do
      write("password" => "x", "order_id" => 1)

      output = described_class.call.to_s

      expect(output).to include("Rows scanned: 1")
      expect(output).to include("WOULD BE STRIPPED")
      expect(output).to include("password")
      expect(output).to include("row(s)")
    end

    it "says so when nothing would be stripped" do
      write("order_id" => 1)

      expect(described_class.call.to_s).to include("Nothing would be stripped.")
    end

    it "flags nested exposure" do
      write("stripe" => { "client_secret" => "sk" })

      output = described_class.call(sensitive_key_patterns: [/secret/i], nested: false).to_s

      expect(output).to include("MATCHES BUT NOT STRIPPED")
      expect(output).to include("stripe.client_secret")
    end
  end
end
