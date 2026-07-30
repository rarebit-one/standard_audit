require "rails_helper"

# `verify_chain` and `backfill_checksums!` both documented a (created_at, id)
# walk and both used `in_batches`, which paginates by PRIMARY KEY range and
# applies the sort only *within* each batch. These examples pin the documented
# order by making id order disagree with (created_at, id) order — which the
# gem's own UUIDv7 ids never do, which is why the defect stayed latent.
RSpec.describe StandardAudit::AuditLog, "chain ordering" do
  before { StandardAudit.instance_variable_set(:@configuration, nil) }

  after { StandardAudit.instance_variable_set(:@configuration, nil) }

  # Ids in the reverse of the intended chain order, so anything that walks by
  # primary key sees the rows backwards.
  def reverse_sorted_ids(count)
    Array.new(count) { SecureRandom.uuid_v7 }.sort.reverse
  end

  def timestamps(count)
    base = 1.hour.ago.change(usec: 0)
    Array.new(count) { |i| base + i.minutes }
  end

  def row_attrs(event_type, id:, at:)
    { id: id, event_type: event_type, occurred_at: at, metadata: {}, created_at: at, updated_at: at }
  end

  # Writes rows that are correctly chained in (created_at, id) order, with ids
  # that sort the other way.
  def insert_reverse_id_chain(count)
    ids = reverse_sorted_ids(count)
    ats = timestamps(count)
    previous = nil

    rows = Array.new(count) do |i|
      row = row_attrs("ordered.#{i}", id: ids[i], at: ats[i])
      row[:checksum] = described_class.compute_checksum_value(row.stringify_keys, previous_checksum: previous)
      previous = row[:checksum]
      row
    end

    described_class.insert_all!(rows)
    rows
  end

  describe ".verify_chain" do
    it "walks (created_at, id) order rather than primary-key order" do
      insert_reverse_id_chain(4)

      result = described_class.verify_chain

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(4)
    end

    it "keeps that order across batch boundaries" do
      insert_reverse_id_chain(6)

      result = described_class.verify_chain(batch_size: 2)

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(6)
    end

    it "still detects tampering when the walk spans several batches" do
      rows = insert_reverse_id_chain(6)
      described_class.where(id: rows[3][:id]).update_all(event_type: "tampered")

      result = described_class.verify_chain(batch_size: 2)

      expect(result[:valid]).to be false
      expect(result[:failures].map { |f| f[:id] }).to eq([rows[3][:id]])
    end

    it "visits every row exactly once when created_at ties are broken by id" do
      at = 1.hour.ago.change(usec: 0)
      ids = Array.new(5) { SecureRandom.uuid_v7 }.sort
      previous = nil

      rows = ids.map.with_index do |id, i|
        row = row_attrs("tied.#{i}", id: id, at: at)
        row[:checksum] = described_class.compute_checksum_value(row.stringify_keys, previous_checksum: previous)
        previous = row[:checksum]
        row
      end

      described_class.insert_all!(rows)

      result = described_class.verify_chain(batch_size: 2)

      expect(result[:failures]).to be_empty
      expect(result[:verified]).to eq(5)
    end

    it "honours the scope filter while walking in chain order" do
      organisation = Organisation.create!(name: "Acme")
      insert_reverse_id_chain(3)

      result = described_class.verify_chain(scope: organisation)

      expect(result[:verified]).to eq(0)
      expect(result[:valid]).to be true
    end
  end

  describe ".backfill_checksums!" do
    it "signs unchecksummed rows in (created_at, id) order" do
      ids = reverse_sorted_ids(3)
      ats = timestamps(3)
      rows = Array.new(3) { |i| row_attrs("legacy.#{i}", id: ids[i], at: ats[i]) }
      described_class.insert_all!(rows)

      expect(described_class.backfill_checksums!(batch_size: 1)).to eq(3)

      first = described_class.find(ids[0])
      expect(first.checksum).to eq(first.compute_checksum_value(previous_checksum: nil))

      second = described_class.find(ids[1])
      expect(second.checksum).to eq(second.compute_checksum_value(previous_checksum: first.checksum))

      expect(described_class.verify_chain[:valid]).to be true
    end
  end
end
