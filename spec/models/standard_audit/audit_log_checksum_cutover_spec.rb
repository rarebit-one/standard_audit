require "rails_helper"

# fundbright/delivery-ops#689: the legacy digest hashed `metadata.to_json` in
# Ruby insertion order, and PostgreSQL jsonb hands keys back in its own order
# (shortest first, then bytewise), so any row with a multi-key object failed
# verify_chain unless its keys happened to be written in jsonb order. Rows
# created at or after the cutover use the canonical digest instead.
#
# Every example runs on both CI legs, and none depends on today's date: rows
# are placed on either side of the cutover explicitly. The keys are chosen so
# the jsonb order is known ("run" sorts before "probe": shorter first), which
# lets the legacy examples store metadata in exactly the order jsonb would
# return it on either backend.
RSpec.describe StandardAudit::AuditLog, "checksum cutover" do
  let(:checksum) { StandardAudit::Checksum }
  let(:fields) { described_class::CHECKSUM_FIELDS }
  let(:cutover) { StandardAudit::CANONICAL_CHECKSUM_CUTOVER }

  before do
    StandardAudit.reset_configuration!(replay_baseline: false)
    @legacy_clock = cutover - 1.day
  end

  after { StandardAudit.reset_configuration!(replay_baseline: false) }

  def postgres?
    described_class.connection.adapter_name.match?(/postg/i)
  end

  def legacy_digest(row, parent)
    checksum.legacy_digest(row.attributes, fields: fields, previous_checksum: parent)
  end

  def canonical_digest(row, parent)
    checksum.canonical_digest(row.attributes, fields: fields, previous_checksum: parent)
  end

  # Inserts a row created BEFORE the cutover, signed with the legacy digest as
  # every existing production row was: `signed` is the metadata in the
  # writer's insertion order, `stored` what the database holds. Pass
  # stored != signed to model a jsonb column that reordered the keys.
  def legacy_row(event_type, signed:, stored: signed, declare_parent: true, parent: described_class.chain_tip_checksum,
    created_at: (@legacy_clock += 0.001))
    created_at = created_at.floor(6)
    id = SecureRandom.uuid_v7
    attrs = { "id" => id, "event_type" => event_type, "metadata" => signed, "occurred_at" => created_at }
    digest = checksum.legacy_digest(attrs, fields: fields, previous_checksum: parent)

    described_class.insert_all!([{
      id: id, event_type: event_type, metadata: stored, occurred_at: created_at,
      checksum: digest, previous_checksum: (parent if declare_parent),
      created_at: created_at, updated_at: created_at
    }])
    described_class.find(id)
  end

  def create_log(event_type, **attrs)
    sleep(0.002)
    described_class.create!(event_type: event_type, occurred_at: Time.current, **attrs)
  end

  # Writes through the normal path with the clock after the cutover.
  def canonical_log(event_type, at: cutover + 1.hour, **attrs)
    travel_to(at, with_usec: true) { create_log(event_type, **attrs) }
  end

  def verify(**options)
    described_class.verify_chain(**options)
  end

  describe "the cutover constant and its override" do
    it "is 2026-10-01T00:00:00Z, frozen, and the default for config.canonical_checksum_since" do
      expect(cutover).to eq(Time.utc(2026, 10, 1, 0, 0, 0))
      expect(cutover).to be_frozen
      expect(StandardAudit.config.canonical_checksum_since).to eq(cutover)
    end

    it "is restored by reset_configuration!" do
      StandardAudit.config.canonical_checksum_since = cutover + 1.day
      StandardAudit.reset_configuration!(replay_baseline: false)

      expect(StandardAudit.config.canonical_checksum_since).to eq(cutover)
    end
  end

  describe "the write path" do
    let(:metadata) { { probe: 2, run: 1 } }

    it "signs a row created before the cutover with the legacy digest" do
      row = travel_to(cutover - 1.hour) { create_log("before", metadata: metadata) }

      expect(row.checksum).to eq(legacy_digest(row, nil))
      expect(row.checksum).not_to eq(canonical_digest(row, nil))
    end

    it "signs a row created at or after the cutover with the canonical digest" do
      row = canonical_log("after", metadata: metadata)

      expect(row.checksum).to eq(canonical_digest(row, nil))
      expect(row.checksum).not_to eq(legacy_digest(row, nil))
    end

    it "switches exactly at the cutover instant, and chains across it" do
      before = travel_to(cutover - 0.000001, with_usec: true) { create_log("just.before", metadata: metadata) }
      after = travel_to(cutover, with_usec: true) { create_log("just.after", metadata: metadata) }

      expect(before.created_at).to be < cutover
      expect(before.checksum).to eq(legacy_digest(before, nil))
      expect(after.created_at).to eq(cutover)
      expect(after.checksum).to eq(canonical_digest(after, before.checksum))
      expect(after.previous_checksum).to eq(before.checksum)
      expect(verify).to include(valid: true, verified: 2)
    end

    it "follows config.canonical_checksum_since when a host moves it" do
      StandardAudit.config.canonical_checksum_since = cutover + 10.days

      delayed = travel_to(cutover + 1.day) { create_log("still.legacy", metadata: metadata) }
      moved = travel_to(cutover + 10.days) { create_log("now.canonical", metadata: metadata) }

      expect(delayed.checksum).to eq(legacy_digest(delayed, nil))
      expect(moved.checksum).to eq(canonical_digest(moved, delayed.checksum))
      expect(verify).to include(valid: true, verified: 2)
    end

    it "decides per row on the batched path, from the created_at it stores" do
      user = User.create!(name: "Alice", email: "alice@example.com")
      travel_to(cutover - 1.hour) { StandardAudit.batch { StandardAudit.record("batch.before", actor: user, metadata: metadata) } }
      travel_to(cutover + 1.hour) { StandardAudit.batch { StandardAudit.record("batch.after", actor: user, metadata: metadata) } }

      before = described_class.find_by!(event_type: "batch.before")
      after = described_class.find_by!(event_type: "batch.after")
      # Re-read rows carry jsonb's key order; the legacy digest covered the
      # writer's insertion order.
      expect(before.checksum).to eq(checksum.legacy_digest(before.attributes.merge("metadata" => metadata), fields: fields))
      expect(after.checksum).to eq(canonical_digest(after, before.checksum))
      expect(verify).to include(valid: true, verified: 2)
    end

    it "backfills each checksum-less row with the algorithm for its own created_at" do
      [cutover - 1.hour, cutover + 1.hour].each_with_index do |at, i|
        described_class.insert_all!([{ id: SecureRandom.uuid_v7, event_type: "old.#{i}", occurred_at: at,
          metadata: { probe: 1, run: 2 }, created_at: at, updated_at: at }])
      end

      travel_to(cutover + 2.days) { described_class.backfill_checksums! }

      before, after = described_class.order(:created_at).to_a
      expect(before.checksum).to eq(legacy_digest(before, nil))
      expect(after.checksum).to eq(canonical_digest(after, before.checksum))
      expect(verify[:valid]).to be(true)
    end
  end

  describe "the Postgres jsonb regression" do
    it "verifies post-cutover rows whose multi-key metadata was written in non-jsonb order" do
      canonical_log("a", metadata: { run: 1, probe: 2 })
      b = canonical_log("b", metadata: { probe: 2, run: 1 }, at: cutover + 2.hours)
      canonical_log("c", metadata: { run: 1 }, at: cutover + 3.hours)
      canonical_log("d", metadata: { zeta: { beta: 1, alpha: [{ y: 1, x: 2 }] }, a: nil, ab: 1.0 }, at: cutover + 4.hours)

      # On Postgres the round trip really did reorder the keys — the state the
      # legacy digest cannot verify. SQLite keeps insertion order.
      expect(described_class.find(b.id).metadata.keys).to eq(postgres? ? %w[run probe] : %w[probe run])

      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, verified: 4, recovered: 0, reordered: 0, legacy_unverifiable: 0)
    end

    it "reproduces the bug under the legacy digest (Postgres only)" do
      skip "SQLite keeps JSON key order, so the legacy digest cannot fail there" unless postgres?

      row = described_class.find(canonical_log("b", metadata: { probe: 2, run: 1 }).id)

      expect(legacy_digest(row, nil)).not_to eq(checksum.legacy_digest(
        row.attributes.merge("metadata" => { "probe" => 2, "run" => 1 }), fields: fields
      ))
      expect(row.compute_checksum_value(previous_checksum: nil)).to eq(row.checksum)
    end

    it "verifies a pre-cutover row written through jsonb by reconstructing its key order" do
      travel_to(cutover - 1.hour) { create_log("legacy", metadata: { probe: 2, run: 1, zz: { yy: 1, x: 2 } }) }

      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, reordered: postgres? ? 1 : 0)
    end
  end

  describe "the canonical digest" do
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
      # Under the legacy digest these hash identically: "target_gid=a|target_type=b|target_type=|…".
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

    it "covers the parent, and differs from the legacy digest" do
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

  describe "linkage across the cutover" do
    it "links the first canonical row to the last legacy row" do
      legacy_row("legacy.1", signed: { run: 1, probe: 2 })
      last_legacy = legacy_row("legacy.2", signed: { run: 3 })
      first = canonical_log("canonical.1", metadata: { probe: 1, run: 2 })
      canonical_log("canonical.2", at: cutover + 2.hours)

      expect(first.previous_checksum).to eq(last_legacy.checksum)
      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, verified: 4)
    end

    it "still links across it when parents are not recorded" do
      legacy_row("legacy.1", signed: { run: 1 }, declare_parent: false)
      canonical_log("canonical.1", metadata: { probe: 1, run: 2 })
      forget_declared_parents

      expect(verify).to include(valid: true, verified: 2, recovered: 0)
    end

    it "reports a canonical row whose legacy parent was removed" do
      legacy_row("legacy.1", signed: { run: 1 }) # opens the walk
      middle = legacy_row("legacy.2", signed: { run: 3 })
      canonical_log("canonical.1")
      described_class.where(id: middle.id).delete_all

      expect(verify[:failures].map { |f| f[:reason] }).to eq([:missing_parent])
    end
  end

  describe "legacy rows" do
    let(:signed) { { probe: 2, run: 1 } }   # the writer's insertion order
    let(:stored) { { run: 1, probe: 2 } }   # the order jsonb hands back

    it "verifies a legacy row whose keys were already in jsonb order, as before" do
      legacy_row("in.order", signed: stored)

      expect(verify).to include(valid: true, verified: 1, reordered: 0)
    end

    it "verifies a legacy row by reconstructing the key order it was signed with" do
      legacy_row("reordered", signed: signed, stored: stored)

      result = verify
      expect(result[:failures]).to be_empty
      expect(result).to include(valid: true, verified: 1, reordered: 1, legacy_unverifiable: 0)
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
      it "lists the row as :legacy_key_order_unverifiable, and it does not make the chain invalid" do
        row = legacy_row("lost", signed: signed, stored: stored)

        result = verify(key_order_search_limit: 0)
        expect(result).to include(valid: true, legacy_unverifiable: 1, reordered: 0, failures: [])
        expect(result[:unverifiable]).to contain_exactly(include(id: row.id, reason: :legacy_key_order_unverifiable))
      end

      it "reports it as a failure with fail_on_legacy_unverifiable: true" do
        row = legacy_row("lost", signed: signed, stored: stored)

        result = verify(key_order_search_limit: 0, fail_on_legacy_unverifiable: true)
        expect(result).to include(valid: false, legacy_unverifiable: 1)
        expect(result[:failures]).to contain_exactly(include(id: row.id, reason: :legacy_key_order_unverifiable))
      end

      it "reports :missing_parent instead when the declared parent is gone" do
        parent = legacy_row("parent", signed: { run: 1 })
        legacy_row("opener", signed: { run: 0 }, parent: nil)
        legacy_row("lost", signed: signed, stored: stored, parent: parent.checksum)
        described_class.where(id: parent.id).delete_all

        result = verify(key_order_search_limit: 0)
        expect(result[:failures]).to contain_exactly(include(reason: :missing_parent, expected: nil))
        expect(result[:legacy_unverifiable]).to eq(0)
      end

      it "gives rows beyond the search limit the same treatment" do
        # Longest key first, so no backend stores it in the signed order.
        signed7 = 7.downto(1).to_h { |i| ["k" * i, i] }
        legacy_row("wide", signed: signed7, stored: signed7.to_a.reverse.to_h)

        expect(verify[:unverifiable].map { |f| f[:reason] }).to eq([:legacy_key_order_unverifiable])
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
      # whose order was lost. It is listed, not hidden.
      it "is listed as unverifiable when the row declares no parent" do
        legacy_row("first", signed: { run: 1 }, declare_parent: false)
        row = legacy_row("tampered", signed: signed, stored: stored, declare_parent: false)
        row.update_columns(metadata: { run: 1, probe: 999 })

        result = verify
        expect(result[:unverifiable]).to contain_exactly(include(id: row.id, reason: :legacy_key_order_unverifiable))
      end
    end
  end

  describe "rows created at or after the cutover" do
    it "are verified strictly: a tampered multi-key row is a :digest_mismatch, never legacy" do
      row = canonical_log("canonical", metadata: { probe: 1, run: 2 })
      row.update_columns(metadata: { probe: 1, run: 3 })

      result = verify
      expect(result).to include(valid: false, legacy_unverifiable: 0)
      expect(result[:failures]).to contain_exactly(include(id: row.id, reason: :digest_mismatch))
    end

    # The upgrade-notes warning: a host still on an older gem after the
    # cutover writes legacy-hashed rows, and those fail strict verification.
    it "fail when an older gem signed them with the legacy digest" do
      at = cutover + 1.hour
      id = SecureRandom.uuid_v7
      attrs = { "id" => id, "event_type" => "old.gem", "metadata" => { run: 1 }, "occurred_at" => at }
      described_class.insert_all!([{ id: id, event_type: "old.gem", metadata: { run: 1 }, occurred_at: at,
        checksum: checksum.legacy_digest(attrs, fields: fields), created_at: at, updated_at: at }])

      expect(verify[:failures]).to contain_exactly(include(id: id, reason: :digest_mismatch))
    end

    # Moving a row back across the cutover makes it legacy-judged. It is
    # listed, and legacy_unverifiable grows — which must never happen after
    # the cutover under honest operation, so hosts should alert on it.
    it "show up in legacy_unverifiable when moved back across the cutover" do
      row = canonical_log("canonical", metadata: { probe: 1, run: 2 })
      baseline = verify[:legacy_unverifiable]
      row.update_columns(created_at: cutover - 1.day, metadata: { probe: 1, run: 3 })

      expect(verify[:legacy_unverifiable]).to eq(baseline + 1)
    end

    it "recover a forked parent" do
      canonical_log("tip")
      travel_to(cutover + 2.hours) { commit(build_concurrent_writers("fork.a", "fork.b")) }
      forget_declared_parents

      expect(verify).to include(valid: true, recovered: 1)
    end

    it "are relinked when their parent was not recorded" do
      canonical_log("tip")
      canonical_log("next", metadata: { probe: 1, run: 2 }, at: cutover + 2.hours)
      forget_declared_parents

      expect(described_class.relink_checksums!).to include(relinked: 1, unresolved: 0)
      expect(verify[:valid]).to be(true)
    end
  end
end
