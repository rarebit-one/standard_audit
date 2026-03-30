require "rails_helper"

RSpec.describe StandardAudit::AuditLog, "checksum chain" do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:order) { Order.create!(total: 99.99) }

  before { StandardAudit.instance_variable_set(:@configuration, nil) }

  after { StandardAudit.instance_variable_set(:@configuration, nil) }

  # Helper: creates records with distinct UUIDv7 timestamps for deterministic
  # ordering. Sleeps 2ms between records so that SecureRandom.uuid_v7 (which
  # uses the real system clock, not travel-mocked time) generates monotonic IDs.
  def create_log(event_type, **attrs)
    sleep(0.002)
    StandardAudit::AuditLog.create!(event_type: event_type, occurred_at: Time.current, **attrs)
  end

  describe "checksum computation on create" do
    it "assigns a checksum when creating a record" do
      log = create_log("test.event")

      expect(log.checksum).to be_present
      expect(log.checksum).to match(/\A[0-9a-f]{64}\z/)
    end

    it "chains checksum to the previous record" do
      first = create_log("first.event")
      second = create_log("second.event")

      expect(second.checksum).not_to eq(first.checksum)

      expected = second.compute_checksum_value(previous_checksum: first.checksum)
      expect(second.checksum).to eq(expected)
    end

    it "first record in chain has no previous checksum" do
      log = create_log("genesis.event")

      expected = log.compute_checksum_value(previous_checksum: nil)
      expect(log.checksum).to eq(expected)
    end

    it "produces deterministic checksums for the same content" do
      attrs = { "id" => "abc-123", "event_type" => "test.event", "occurred_at" => Time.current }
      checksum1 = StandardAudit::AuditLog.compute_checksum_value(attrs)
      checksum2 = StandardAudit::AuditLog.compute_checksum_value(attrs)

      expect(checksum1).to eq(checksum2)
    end
  end

  describe ".verify_chain" do
    it "returns valid for an untampered chain" do
      3.times { |i| create_log("chain.#{i}") }

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(3)
      expect(result[:failures]).to be_empty
    end

    it "detects tampered records" do
      create_log("original.first")
      log2 = create_log("original.second")
      create_log("original.third")

      log2.update_columns(event_type: "tampered.second")

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be false
      expect(result[:failures].first[:id]).to eq(log2.id)
    end

    it "detects tampered metadata" do
      log = create_log("metadata.test", metadata: { action: "create" })

      log.update_columns(metadata: { action: "delete" })

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be false
      expect(result[:failures].first[:id]).to eq(log.id)
    end

    it "skips records without checksums" do
      StandardAudit::AuditLog.insert_all!([{
        id: SecureRandom.uuid,
        event_type: "legacy.event",
        occurred_at: Time.current,
        metadata: {},
        created_at: 1.hour.ago,
        updated_at: 1.hour.ago
      }])

      create_log("new.event")

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(1)
    end

    it "returns valid for an empty table" do
      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(0)
    end
  end

  describe ".backfill_checksums!" do
    it "backfills checksums for records that lack them" do
      3.times do |i|
        StandardAudit::AuditLog.insert_all!([{
          id: SecureRandom.uuid_v7,
          event_type: "legacy.#{i}",
          occurred_at: Time.current,
          metadata: {},
          created_at: Time.current + i.seconds,
          updated_at: Time.current + i.seconds
        }])
      end

      expect(StandardAudit::AuditLog.where(checksum: nil).count).to eq(3)

      count = StandardAudit::AuditLog.backfill_checksums!
      expect(count).to eq(3)

      expect(StandardAudit::AuditLog.where(checksum: nil).count).to eq(0)

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be true
    end

    it "skips records that already have checksums" do
      create_log("existing.event")

      count = StandardAudit::AuditLog.backfill_checksums!
      expect(count).to eq(0)
    end
  end

  describe "batch mode checksums" do
    it "computes chained checksums in batch mode" do
      StandardAudit.batch do
        StandardAudit.record("batch.first", actor: user)
        StandardAudit.record("batch.second", actor: user)
      end

      logs = StandardAudit::AuditLog.order(created_at: :asc, id: :asc)
      expect(logs.pluck(:checksum)).to all(be_present)

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(2)
    end

    it "chains batch checksums to existing records" do
      create_log("pre.batch")

      StandardAudit.batch do
        StandardAudit.record("batch.after", actor: user)
      end

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(2)
    end
  end

  describe "GDPR anonymization interaction" do
    it "anonymization breaks the chain as expected" do
      log = StandardAudit.record("gdpr.test", actor: user, metadata: { email: "alice@example.com" })

      log.update_columns(
        actor_gid: "[anonymized]",
        actor_type: "[anonymized]",
        ip_address: nil
      )

      result = StandardAudit::AuditLog.verify_chain
      expect(result[:valid]).to be false
      expect(result[:failures].first[:id]).to eq(log.id)
    end
  end
end
