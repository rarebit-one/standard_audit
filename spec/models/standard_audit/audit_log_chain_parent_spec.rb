require "rails_helper"

RSpec.describe StandardAudit::AuditLog, "chain parents" do
  before { StandardAudit.instance_variable_set(:@configuration, nil) }

  after { StandardAudit.instance_variable_set(:@configuration, nil) }

  describe "recording the parent on write" do
    it "records nothing for the first row" do
      expect(create_log("genesis").previous_checksum).to be_nil
    end

    it "records the tip the writer read" do
      first = create_log("first")
      second = create_log("second")

      expect(second.previous_checksum).to eq(first.checksum)
      expect(second.checksum).to eq(second.compute_checksum_value(previous_checksum: first.checksum))
    end

    it "records the same parent for both sides of a fork" do
      tip = create_log("tip")
      writers = build_concurrent_writers("fork.a", "fork.b")
      commit(writers)

      expect(writers.map(&:previous_checksum)).to eq([tip.checksum, tip.checksum])
    end

    it "records parents on the batched write path" do
      user = User.create!(name: "Alice", email: "alice@example.com")
      tip = create_log("tip")

      StandardAudit.batch do
        StandardAudit.record("batch.first", actor: user)
        StandardAudit.record("batch.second", actor: user)
      end

      batched = described_class.where.not(id: tip.id).order(created_at: :asc, id: :asc)
      expect(batched.first.previous_checksum).to eq(tip.checksum)
      expect(batched.second.previous_checksum).to eq(batched.first.checksum)
      expect(described_class.verify_chain[:valid]).to be true
    end

    it "records parents when backfilling pre-checksum rows" do
      3.times do |i|
        described_class.insert_all!([{
          id: SecureRandom.uuid_v7,
          event_type: "legacy.#{i}",
          occurred_at: Time.current,
          metadata: {},
          created_at: Time.current + i.seconds,
          updated_at: Time.current + i.seconds
        }])
      end

      described_class.backfill_checksums!

      rows = described_class.order(created_at: :asc, id: :asc).to_a
      expect(rows.first.previous_checksum).to be_nil
      expect(rows.second.previous_checksum).to eq(rows.first.checksum)
      expect(described_class.verify_chain[:valid]).to be true
    end
  end

  describe ".verify_chain with recorded parents" do
    it "accepts a forked log" do
      create_log("tip")
      commit(build_concurrent_writers("fork.a", "fork.b", "fork.c"))

      result = described_class.verify_chain

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(4)
      expect(result[:recovered]).to eq(0)
    end

    it "accepts a row written after a fork" do
      create_log("tip")
      first, second = build_concurrent_writers("fork.a", "fork.b")
      commit([first, second])
      third = create_log("after.fork")

      expect(third.previous_checksum).to eq(second.checksum)
      expect(described_class.verify_chain[:valid]).to be true
    end

    it "still detects a tampered field" do
      create_log("first")
      tampered = create_log("second")
      create_log("third")

      tampered.update_columns(event_type: "tampered")

      result = described_class.verify_chain

      expect(result[:valid]).to be false
      expect(result[:failures].map { |f| f[:id] }).to eq([tampered.id])
      expect(result[:failures].first[:reason]).to eq(:digest_mismatch)
    end

    it "detects a rewritten parent pointer" do
      first = create_log("first")
      second = create_log("second")
      third = create_log("third")

      third.update_columns(previous_checksum: first.checksum)

      result = described_class.verify_chain

      expect(result[:valid]).to be false
      expect(result[:failures].map { |f| f[:id] }).to eq([third.id])
      expect(second.reload.checksum).to be_present
    end

    it "detects a row removed from the middle of the log" do
      create_log("first")
      removed = create_log("second")
      third = create_log("third")

      described_class.where(id: removed.id).delete_all

      result = described_class.verify_chain

      expect(result[:valid]).to be false
      expect(result[:failures].map { |f| f[:id] }).to eq([third.id])
      expect(result[:failures].first[:reason]).to eq(:missing_parent)
    end

    it "does not flag the oldest surviving row after retention pruning" do
      pruned = create_log("old")
      create_log("kept.first")
      create_log("kept.second")

      described_class.where(id: pruned.id).delete_all

      result = described_class.verify_chain

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
    end

    it "does not flag either child of a pruned parent they forked off" do
      pruned = create_log("old")
      commit(build_concurrent_writers("fork.a", "fork.b"))

      described_class.where(id: pruned.id).delete_all

      result = described_class.verify_chain

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
    end

    it "does not flag survivors when a pruned prefix held several forks" do
      pruned = [create_log("old.first"), create_log("old.second")]
      commit(build_concurrent_writers("fork.a", "fork.b"))
      create_log("later")

      described_class.where(id: pruned.map(&:id)).delete_all

      expect(described_class.verify_chain[:failures]).to be_empty
    end

    it "still flags a removal that happens after the pruned prefix" do
      pruned = create_log("old")
      create_log("kept")
      removed = create_log("removed")
      last = create_log("last")

      described_class.where(id: [pruned.id, removed.id]).delete_all

      result = described_class.verify_chain

      expect(result[:failures].map { |f| f[:id] }).to eq([last.id])
      expect(result[:failures].first[:reason]).to eq(:missing_parent)
    end

    it "does not flag missing parents when scoped, since the chain is global" do
      organisation = Organisation.create!(name: "Acme")
      create_log("unscoped")
      scoped = create_log("scoped", scope_gid: organisation.to_global_id.to_s, scope_type: "Organisation")

      result = described_class.verify_chain(scope: organisation)

      expect(result[:failures]).to be_empty
      expect(result[:verified]).to eq(1)
      expect(scoped.previous_checksum).to be_present
    end
  end

  describe ".verify_chain with pre-0.8 rows that carry no parent" do
    it "recovers the parent of a forked row and reports it" do
      create_log("tip")
      commit(build_concurrent_writers("fork.a", "fork.b", "fork.c"))
      forget_declared_parents

      result = described_class.verify_chain

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
      expect(result[:recovered]).to eq(2)
    end

    it "reports the fork as a failure under strict:" do
      create_log("tip")
      commit(build_concurrent_writers("fork.a", "fork.b"))
      forget_declared_parents

      result = described_class.verify_chain(strict: true)

      expect(result[:valid]).to be false
      expect(result[:recovered]).to eq(0)
    end

    it "does not recover a tampered row" do
      create_log("first")
      tampered = create_log("second")
      create_log("third")
      forget_declared_parents
      tampered.update_columns(event_type: "tampered")

      result = described_class.verify_chain

      expect(result[:valid]).to be false
      expect(result[:failures].map { |f| f[:id] }).to eq([tampered.id])
    end

    it "does not search past the recovery window" do
      create_log("tip")
      commit(build_concurrent_writers("fork.a", "fork.b"))
      3.times { |i| create_log("after.#{i}") }
      forget_declared_parents

      expect(described_class.verify_chain(recovery_window: 1)[:valid]).to be false
      expect(described_class.verify_chain(recovery_window: 8)[:valid]).to be true
    end
  end

  describe "a host that has not run the migration" do
    before { allow(described_class).to receive(:chain_parent_column?).and_return(false) }

    it "writes rows without touching the column" do
      create_log("first")
      second = create_log("second")

      expect(second.previous_checksum).to be_nil
      expect(second.checksum).to be_present
    end

    it "still recovers forked rows on verification" do
      create_log("tip")
      commit(build_concurrent_writers("fork.a", "fork.b"))

      result = described_class.verify_chain

      expect(result[:valid]).to be true
      expect(result[:recovered]).to eq(1)
    end

    it "relinks nothing" do
      create_log("first")

      expect(described_class.relink_checksums!).to eq(relinked: 0, unresolved: 0, skipped: 0)
    end
  end

  describe ".relink_checksums!" do
    it "records the parent each unlinked row was actually signed against" do
      tip = create_log("tip")
      first, second = build_concurrent_writers("fork.a", "fork.b")
      commit([first, second])
      forget_declared_parents

      expect(described_class.relink_checksums!).to eq(relinked: 2, unresolved: 0, skipped: 1)

      expect(first.reload.previous_checksum).to eq(tip.checksum)
      expect(second.reload.previous_checksum).to eq(tip.checksum)
      expect(tip.reload.previous_checksum).to be_nil
      expect(described_class.verify_chain).to include(valid: true, recovered: 0)
    end

    it "never rewrites a checksum" do
      create_log("first")
      create_log("second")
      forget_declared_parents
      before_digests = described_class.order(:created_at).pluck(:checksum)

      described_class.relink_checksums!

      expect(described_class.order(:created_at).pluck(:checksum)).to eq(before_digests)
    end

    it "leaves a tampered row unresolved rather than papering over it" do
      create_log("first")
      tampered = create_log("second")
      forget_declared_parents
      tampered.update_columns(event_type: "tampered")

      expect(described_class.relink_checksums!).to include(unresolved: 1)
      expect(tampered.reload.previous_checksum).to be_nil
      expect(described_class.verify_chain[:valid]).to be false
    end

    it "leaves rows that already carry a parent alone" do
      create_log("first")
      create_log("second")

      expect(described_class.relink_checksums!).to eq(relinked: 0, unresolved: 0, skipped: 2)
    end
  end
end
