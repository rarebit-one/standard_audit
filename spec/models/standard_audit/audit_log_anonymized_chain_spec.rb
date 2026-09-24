require "rails_helper"
require "rails/generators"
require "generators/standard_audit/add_anonymized_at/add_anonymized_at_generator"

RSpec.describe StandardAudit::AuditLog, "anonymization and the checksum chain" do
  let(:alice) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:bob) { User.create!(name: "Bob", email: "bob@example.com") }

  before { StandardAudit.reset_configuration!(replay_baseline: false) }

  after { StandardAudit.reset_configuration!(replay_baseline: false) }

  def write(event, actor)
    StandardAudit.record(event, actor: actor, metadata: { email: actor.email, note: event },
      ip_address: "10.0.0.1", session_id: "sess")
  end

  def chain_with_anonymized_middle
    write("first", bob)
    middle = write("middle", alice)
    write("last", bob)
    described_class.anonymize_actor!(alice)
    middle.reload
  end

  it "stamps anonymized_at and leaves the stored checksum untouched" do
    middle = write("middle", alice)
    original_checksum = middle.checksum

    freeze_time do
      described_class.anonymize_actor!(alice)
      middle.reload

      expect(middle.anonymized_at).to eq(Time.current)
    end
    expect(middle.checksum).to eq(original_checksum)
    expect(middle.actor_gid).to eq("[anonymized]")
    expect(middle).to be_anonymized
  end

  it "keeps the first stamp when a row is anonymized twice" do
    middle = write("middle", alice)
    travel_to(2.days.ago) { described_class.anonymize_actor!(alice) }
    first_stamp = middle.reload.anonymized_at

    described_class.anonymize_actor!(alice)

    expect(middle.reload.anonymized_at).to eq(first_stamp)
  end

  it "verifies a chain with an anonymized middle row as valid, counting it as redacted" do
    chain_with_anonymized_middle

    result = described_class.verify_chain

    expect(result).to include(valid: true, verified: 2, redacted: 1, failures: [])
  end

  it "verifies it valid without the previous_checksum column too" do
    chain_with_anonymized_middle
    described_class.update_all(previous_checksum: nil)
    allow(described_class).to receive(:chain_parent_column?).and_return(false)

    expect(described_class.verify_chain).to include(valid: true, verified: 2, redacted: 1)
  end

  it "still detects tampering on the rows around the anonymized one" do
    chain_with_anonymized_middle
    described_class.find_by(event_type: "last").update_columns(event_type: "tampered")

    result = described_class.verify_chain

    expect(result[:valid]).to be(false)
    expect(result[:failures].map { |f| f[:event_type] }).to eq(["tampered"])
    expect(result[:failures].first[:reason]).to eq(:digest_mismatch)
  end

  it "still reports a missing parent for an anonymized row" do
    write("first", bob)
    removed = write("second", bob)
    write("middle", alice)
    described_class.anonymize_actor!(alice)
    removed.delete

    result = described_class.verify_chain

    expect(result[:valid]).to be(false)
    expect(result[:failures].map { |f| [f[:event_type], f[:reason]] }).to eq([["middle", :missing_parent]])
  end

  context "when the host has not added the anonymized_at column" do
    before { allow(described_class).to receive(:anonymization_column?).and_return(false) }

    it "still anonymizes, and verify_chain reports the row as before" do
      middle = write("middle", alice)
      write("last", bob)

      expect(described_class.anonymize_actor!(alice)).to eq(1)
      expect(middle.reload.actor_gid).to eq("[anonymized]")
      expect(middle.anonymized_at).to be_nil

      result = described_class.verify_chain
      expect(result).to include(valid: false, redacted: 0)
      expect(result[:failures].map { |f| f[:reason] }).to eq([:digest_mismatch])
    end
  end

  describe "the add_anonymized_at generator" do
    let(:destination_root) { File.expand_path("../../../tmp/add_anonymized_at_test", __dir__) }

    before do
      FileUtils.rm_rf(destination_root)
      FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    end

    after { FileUtils.rm_rf(destination_root) }

    it "adds a nullable column idempotently" do
      Dir.chdir(destination_root) do
        generator = StandardAudit::Generators::AddAnonymizedAtGenerator.new([], {})
        generator.destination_root = destination_root
        generator.invoke_all
      end
      content = File.read(Dir.glob(File.join(destination_root, "db/migrate/*_add_anonymized_at_to_audit_logs.rb")).first)

      expect(content).to include("add_column :audit_logs, :anonymized_at, :datetime")
      expect(content).to include("return if column_exists?(:audit_logs, :anonymized_at)")
      expect(content).not_to include("null: false")
    end
  end
end
