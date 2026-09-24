require "rails_helper"

# fundbright/delivery-ops#689: the v1 digest hashed `metadata.to_json` in Ruby
# insertion order, and PostgreSQL jsonb hands keys back in its own order
# (shortest first, then bytewise), so any row with a multi-key object failed
# verify_chain unless its keys happened to be written in jsonb order.
#
# Every example here runs on both CI legs. The keys are chosen so that the
# jsonb order is known ("run" sorts before "probe": shorter first), which lets
# the legacy examples store metadata in exactly the order jsonb would return
# it on either backend.
RSpec.describe StandardAudit::AuditLog, "checksum versions" do
  let(:checksum) { StandardAudit::Checksum }
  let(:fields) { described_class::CHECKSUM_FIELDS }

  before { StandardAudit.reset_configuration!(replay_baseline: false) }

  after { StandardAudit.reset_configuration!(replay_baseline: false) }

  def postgres?
    described_class.connection.adapter_name.match?(/postg/i)
  end

  # Inserts a row signed with the LEGACY (v1) digest, as 0.13 and earlier
  # wrote it: `signed` is the metadata in the writer's insertion order, and
  # `stored` is what the database holds. Pass stored != signed to model a
  # jsonb column that reordered the keys.
  def legacy_row(event_type, signed:, stored: signed, declare_parent: true, parent: described_class.chain_tip_checksum)
    sleep(0.002)
    now = Time.current.floor(6)
    id = SecureRandom.uuid_v7
    attrs = { "id" => id, "event_type" => event_type, "metadata" => signed, "occurred_at" => now }
    digest = checksum.legacy_digest(attrs, fields: fields, previous_checksum: parent)

    described_class.insert_all!([{
      id: id, event_type: event_type, metadata: stored, occurred_at: now,
      checksum: digest, previous_checksum: (parent if declare_parent), checksum_version: nil,
      created_at: now, updated_at: now
    }])
    described_class.find(id)
  end

  def create_log(event_type, **attrs)
    sleep(0.002)
    described_class.create!(event_type: event_type, occurred_at: Time.current, **attrs)
  end

  def verify(**options)
    described_class.verify_chain(**options)
  end

  describe "the Postgres jsonb regression" do
    it "verifies rows whose multi-key metadata was written in non-jsonb order" do
      create_log("a", metadata: { run: 1, probe: 2 })
      b = create_log("b", metadata: { probe: 2, run: 1 })
      create_log("c", metadata: { run: 1 })
      create_log("d", metadata: { zeta: { beta: 1, alpha: [{ y: 1, x: 2 }] }, a: nil, ab: 1.0 })

      stored_keys = described_class.find(b.id).metadata.keys
      # On Postgres the round trip really did reorder the keys — this is the
      # state 0.13 could not verify. SQLite keeps insertion order.
      expect(stored_keys).to eq(postgres? ? %w[run probe] : %w[probe run])

      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, verified: 4, recovered: 0, reordered: 0, legacy_unverifiable: 0)
    end

    it "reproduces the 0.13 failure under the v1 digest (Postgres only)" do
      skip "SQLite keeps JSON key order, so v1 cannot fail there" unless postgres?

      log = create_log("b", metadata: { probe: 2, run: 1 })
      reloaded = described_class.find(log.id)

      expect(reloaded.compute_checksum_value(previous_checksum: nil, version: checksum::LEGACY)).not_to eq(reloaded.checksum)
      expect(reloaded.compute_checksum_value(previous_checksum: nil)).to eq(reloaded.checksum)
    end

    it "marks new rows as v2 on every write path" do
      user = User.create!(name: "Alice", email: "alice@example.com")
      direct = create_log("direct", metadata: { b: 1, a: 2 })
      StandardAudit.batch { StandardAudit.record("batched", actor: user, metadata: { b: 1, a: 2 }) }

      expect(direct.checksum_version).to eq(2)
      expect(described_class.find_by!(event_type: "batched").checksum_version).to eq(2)
      expect(verify[:valid]).to be(true)
    end

    it "backfills checksum-less rows as v2" do
      described_class.insert_all!([{ id: SecureRandom.uuid_v7, event_type: "old", occurred_at: Time.current,
        metadata: { probe: 1, run: 2 }, created_at: Time.current, updated_at: Time.current }])

      described_class.backfill_checksums!

      expect(described_class.sole.checksum_version).to eq(2)
      expect(verify[:valid]).to be(true)
    end
  end

  describe "the canonical (v2) digest" do
    let(:base) { { "id" => "id-1", "event_type" => "e", "occurred_at" => Time.utc(2026, 9, 25, 1, 2, 3, 456_789.123r) } }

    def v2(attrs, parent = nil)
      checksum.canonical_digest(base.merge(attrs), fields: fields, previous_checksum: parent)
    end

    it "is independent of key order at every depth, and of symbol vs string keys" do
      a = v2("metadata" => { b: 1, a: { d: [{ f: 1, e: 2 }], c: 3 } })
      b = v2("metadata" => { "a" => { "c" => 3, "d" => [{ "e" => 2, "f" => 1 }] }, "b" => 1 })

      expect(a).to eq(b)
    end

    it "keeps array order significant" do
      expect(v2("metadata" => { a: [1, 2] })).not_to eq(v2("metadata" => { a: [2, 1] }))
    end

    it "hashes values as the JSON the column stores" do
      time = Time.utc(2026, 1, 1)
      expect(v2("metadata" => { at: time, n: 1.0, big: 1e20, sym: :x }))
        .to eq(v2("metadata" => { "at" => time.as_json, "n" => 1, "big" => 100_000_000_000_000_000_000, "sym" => "x" }))
    end

    it "distinguishes nil from an empty string" do
      expect(v2("request_id" => nil)).not_to eq(v2("request_id" => ""))
    end

    it "does not let a separator inside a value shift content between fields" do
      # Under v1 these two rows hash identically: "target_gid=a|target_type=b|target_type=|…".
      shifted = { "target_gid" => "a|target_type=b", "target_type" => "" }
      plain = { "target_gid" => "a", "target_type" => "b|target_type=" }

      expect(checksum.legacy_digest(base.merge(shifted), fields: fields))
        .to eq(checksum.legacy_digest(base.merge(plain), fields: fields))
      expect(v2(shifted)).not_to eq(v2(plain))
    end

    it "is the SHA-256 of the documented canonical payload" do
      attrs = base.merge("metadata" => { b: 1, a: [1.0, nil] }, "request_id" => "r\"1")
      payload = checksum.canonical_payload(attrs, fields: fields, previous_checksum: "abc")

      expect(v2(attrs.except(*base.keys), "abc"))
        .to eq(OpenSSL::Digest::SHA256.hexdigest(checksum.canonical_json(payload)))
      expect(v2(attrs.except(*base.keys)))
        .to eq(OpenSSL::Digest::SHA256.hexdigest(checksum.canonical_json(payload.merge("previous_checksum" => nil))))
    end

    it "covers the parent and the version" do
      expect(v2({}, "p")).not_to eq(v2({}))
      expect(v2({})).not_to eq(checksum.legacy_digest(base, fields: fields))
    end

    it "escapes strings at the byte level, including invalid UTF-8" do
      expect(checksum.canonical_json({ "k" => "a\"b\\c\n\u0001é" }))
        .to eq("{\"k\":\"a\\\"b\\\\c\\u000a\\u0001é\"}".b)
      expect { checksum.canonical_json("\xFF\xFE") }.not_to raise_error
    end

    it "sorts keys bytewise, not by length as jsonb does" do
      expect(checksum.canonical_json({ "probe" => 1, "run" => 2, "B" => 3 })).to eq('{"B":3,"probe":1,"run":2}')
    end
  end

  describe "the v1 → v2 boundary" do
    it "links the first v2 row to the last legacy row" do
      legacy_row("legacy.1", signed: { run: 1, probe: 2 })
      last_legacy = legacy_row("legacy.2", signed: { run: 3 })
      first_v2 = create_log("v2.1", metadata: { probe: 1, run: 2 })
      create_log("v2.2")

      expect(first_v2.previous_checksum).to eq(last_legacy.checksum)
      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, verified: 4)
    end

    it "still links across the boundary when parents are not recorded" do
      legacy_row("legacy.1", signed: { run: 1 }, declare_parent: false)
      create_log("v2.1", metadata: { probe: 1, run: 2 })
      forget_declared_parents

      expect(verify).to include(valid: true, verified: 2, recovered: 0)
    end

    it "reports a v2 row whose declared parent was removed" do
      legacy_row("legacy.1", signed: { run: 1 }) # opens the walk
      middle = legacy_row("legacy.2", signed: { run: 3 })
      create_log("v2.1")
      described_class.where(id: middle.id).delete_all

      expect(verify[:failures].map { |f| f[:reason] }).to include(:missing_parent)
    end
  end

  describe "legacy rows" do
    let(:signed) { { probe: 2, run: 1 } }   # the writer's insertion order
    let(:stored) { { run: 1, probe: 2 } }   # the order jsonb hands back

    it "verifies a legacy row whose keys were already in jsonb order, as 0.13 did" do
      legacy_row("in.order", signed: stored)

      expect(verify).to include(valid: true, verified: 1, reordered: 0)
    end

    it "verifies a legacy row by reconstructing the key order it was signed with" do
      legacy_row("reordered", signed: signed, stored: stored)

      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, verified: 1, reordered: 1, legacy_unverifiable: 0)
    end

    it "reconstructs a legacy row whose keys the database itself reordered" do
      # What production holds: a 0.13 writer's hash, written straight through
      # the column. jsonb reorders it; SQLite does not.
      legacy_row("through.column", signed: { probe: 2, run: 1, zz: { yy: 1, x: 2 } })

      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, reordered: postgres? ? 1 : 0)
    end

    it "reconstructs nested key orders too" do
      legacy_row("nested", signed: { outer: { b: 1, a: 2 }, id: 1 }, stored: { id: 1, outer: { a: 2, b: 1 } })

      expect(verify).to include(valid: true, reordered: 1)
    end

    it "reconstructs rows that do not declare a parent" do
      legacy_row("first", signed: { run: 1 }, declare_parent: false)
      legacy_row("reordered", signed: signed, stored: stored, declare_parent: false)

      expect(verify).to include(valid: true, reordered: 1)
    end

    it "reuses an order learned from an earlier row with the same keys" do
      3.times { |i| legacy_row("otp.#{i}", signed: { probe: i, run: 1 }, stored: { run: 1, probe: i }) }
      searches = 0
      allow(StandardAudit::Checksum::KeyOrderSearch).to receive(:variants).and_wrap_original do |m, node|
        searches += 1 if node.is_a?(Hash) && node.key?("probe") # top-level calls only, not the recursion
        m.call(node)
      end

      expect(verify).to include(valid: true, reordered: 3)
      expect(searches).to eq(1) # full enumeration once; the other two rows hit the learned order
    end

    context "when the key order cannot be reconstructed" do
      it "reports :legacy_key_order_unverifiable, and valid is false by default" do
        row = legacy_row("lost", signed: signed, stored: stored)

        result = verify(key_order_search_limit: 0)
        expect(result).to include(valid: false, legacy_unverifiable: 1, reordered: 0)
        expect(result[:failures]).to contain_exactly(include(id: row.id, reason: :legacy_key_order_unverifiable))
      end

      it "leaves rows created before accept_legacy_unverifiable_before out of the failures" do
        legacy_row("lost", signed: signed, stored: stored)

        result = verify(key_order_search_limit: 0, accept_legacy_unverifiable_before: 1.minute.from_now)
        expect(result).to include(valid: true, legacy_unverifiable: 1, failures: [])
      end

      it "still fails rows created at or after the accepted cutover" do
        cutover = Time.current
        legacy_row("lost", signed: signed, stored: stored)

        result = verify(key_order_search_limit: 0, accept_legacy_unverifiable_before: cutover)
        expect(result[:valid]).to be(false)
        expect(result[:failures].map { |f| f[:reason] }).to eq([:legacy_key_order_unverifiable])
      end

      it "reports :missing_parent instead when the declared parent is gone" do
        parent = legacy_row("parent", signed: { run: 1 })
        legacy_row("opener", signed: { run: 0 }, parent: nil)
        legacy_row("lost", signed: signed, stored: stored, parent: parent.checksum)
        described_class.where(id: parent.id).delete_all

        expect(verify(key_order_search_limit: 0)[:failures].map { |f| f[:reason] }).to eq([:missing_parent])
      end

      it "gives rows beyond the search limit the same treatment" do
        # Longest key first, so no backend stores it in the signed order.
        signed7 = 7.downto(1).to_h { |i| ["k" * i, i] }
        legacy_row("wide", signed: signed7, stored: signed7.to_a.reverse.to_h)

        expect(verify[:failures].map { |f| f[:reason] }).to eq([:legacy_key_order_unverifiable])
      end
    end

    context "when a legacy row was tampered with" do
      it "is a :digest_mismatch when every key order was tried against its declared parent" do
        legacy_row("parent", signed: { run: 0 })
        row = legacy_row("tampered", signed: signed, stored: stored)
        row.update_columns(metadata: { run: 1, probe: 999 })

        result = verify
        expect(result[:valid]).to be(false)
        expect(result[:failures]).to contain_exactly(include(id: row.id, reason: :digest_mismatch))
      end

      it "is a :digest_mismatch for a row with no multi-key object" do
        row = legacy_row("single", signed: { run: 1 })
        row.update_columns(metadata: { run: 2 })

        expect(verify[:failures]).to contain_exactly(include(id: row.id, reason: :digest_mismatch))
      end

      it "is a :digest_mismatch when a non-metadata field was edited on a single-key row" do
        row = legacy_row("edited", signed: { run: 1 })
        row.update_columns(event_type: "edited.later")

        expect(verify[:failures]).to contain_exactly(include(id: row.id, reason: :digest_mismatch))
      end

      # Honest limitation: without a known parent the search is not
      # conclusive, so an edited multi-key row cannot be told apart from one
      # whose order was lost. It is still a failure unless the host accepted
      # legacy rows before a cutover.
      it "is unverifiable, and still a failure, when the row declares no parent" do
        legacy_row("first", signed: { run: 1 }, declare_parent: false)
        row = legacy_row("tampered", signed: signed, stored: stored, declare_parent: false)
        row.update_columns(metadata: { run: 1, probe: 999 })

        result = verify
        expect(result[:valid]).to be(false)
        expect(result[:failures]).to contain_exactly(include(id: row.id, reason: :legacy_key_order_unverifiable))
      end
    end
  end

  describe "v2 rows" do
    it "are never classified as legacy: a tampered multi-key v2 row is a :digest_mismatch" do
      row = create_log("v2", metadata: { probe: 1, run: 2 })
      row.update_columns(metadata: { probe: 1, run: 3 })

      result = verify(accept_legacy_unverifiable_before: 1.minute.from_now)
      expect(result[:valid]).to be(false)
      expect(result[:failures]).to contain_exactly(include(id: row.id, reason: :digest_mismatch))
    end

    it "cannot be passed off as legacy after the cutover by clearing the version" do
      cutover = Time.current
      row = create_log("v2", metadata: { probe: 1, run: 2 })
      forged = checksum.legacy_digest(row.attributes.merge("metadata" => { "probe" => 1, "run" => 3 }), fields: fields,
        previous_checksum: row.previous_checksum)
      row.update_columns(metadata: { probe: 1, run: 3 }, checksum_version: nil, checksum: forged.reverse)

      result = verify(accept_legacy_unverifiable_before: cutover)
      expect(result[:valid]).to be(false)
      expect(result[:failures].map { |f| f[:id] }).to eq([row.id])
    end

    it "reports an unknown version" do
      row = create_log("future")
      row.update_columns(checksum_version: 3)

      expect(verify[:failures]).to contain_exactly(include(id: row.id, reason: :unsupported_checksum_version))
    end

    it "recover a forked parent under v2" do
      create_log("tip")
      commit(build_concurrent_writers("fork.a", "fork.b"))
      forget_declared_parents

      expect(verify).to include(valid: true, recovered: 1)
    end

    it "are relinked when their parent was not recorded" do
      create_log("tip")
      create_log("next", metadata: { probe: 1, run: 2 })
      forget_declared_parents

      expect(described_class.relink_checksums!).to include(relinked: 1, unresolved: 0)
      expect(verify[:valid]).to be(true)
    end
  end

  describe "a host without the checksum_version column" do
    before { allow(described_class).to receive(:checksum_version_column?).and_return(false) }

    it "writes unmarked v2 rows, and verifies them alongside legacy rows" do
      legacy_row("legacy", signed: { run: 1 })
      log = create_log("unmarked", metadata: { probe: 1, run: 2 })

      expect(log.checksum).to eq(log.compute_checksum_value(previous_checksum: log.previous_checksum, version: 2))
      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, verified: 2)
    end

    it "still detects a tampered single-key row" do
      row = create_log("unmarked", metadata: { run: 1 })
      row.update_columns(metadata: { run: 2 })

      expect(verify[:failures]).to contain_exactly(include(id: row.id, reason: :digest_mismatch))
    end
  end
end
