require "rails_helper"

# Reproduction of the concurrent-append defect behind
# fundbright/delivery-ops#433 — `verify_chain` fails for 67% of production
# audit rows because `compute_checksum` reads the chain tip with an
# unsynchronised query from `before_create`.
#
# WHAT IS SIMULATED, AND WHAT IS NOT
#
# The gem's dummy app runs on in-memory SQLite, and SQLite cannot exhibit this
# race at all: it serialises writers at the database level. Two overlapping
# write transactions never both commit — in rollback-journal mode the second
# writer's SHARED lock blocks the first one's COMMIT, and in WAL mode a
# read-then-write transaction whose snapshot went stale fails with
# SQLITE_BUSY_SNAPSHOT. SQLite is, in effect, the global lock the chain design
# assumes and Postgres does not provide. That is exactly why 301 green examples
# never caught a defect that voids two production rows in three.
#
# So these examples do not spawn threads. They reproduce the *state* two
# concurrent READ COMMITTED transactions produce, using only the gem's real
# code path and no stubs: each writer runs the model's own `before_create`
# chain (`assign_uuid` -> before_checksum hooks -> `compute_checksum`) against
# the same committed snapshot of the table — neither can see the other's
# uncommitted row — and then both commit.
#
# This PROVES:
#   * two writers can observe the same tip and both persist;
#   * what `verify_chain` then makes of it. Before 0.8.0 it reported the later
#     writers as failures, in the exact shape measured on production (N
#     simultaneous writers off one tip => N-1 failures, which is why three
#     events from a single OTP request failed in identical counts).
#
# This does NOT PROVE:
#   * that the interleave is reachable on any particular runtime. That is an
#     argument from Postgres READ COMMITTED semantics plus the production
#     measurements in the issue, not something this suite can demonstrate
#     without a Postgres-backed dummy app (see the issue for the measurement).
#
# These examples were `pending` when they were written, against the unfixed
# gem. They pass as of 0.8.0, which records the parent each row was signed
# against instead of assuming the sequence never forks.
RSpec.describe StandardAudit::AuditLog, "concurrent appends" do
  before { StandardAudit.instance_variable_set(:@configuration, nil) }

  after { StandardAudit.instance_variable_set(:@configuration, nil) }

  # `commit` re-runs the whole before_create chain on a record that already ran
  # it, which is a no-op only while no before_checksum hook is registered:
  # assign_uuid and compute_checksum both guard on their own output, but hooks
  # do not, and a hook that ran twice would fail these examples for a reason
  # that has nothing to do with the race. Pinned rather than assumed.
  it "depends on no before_checksum hook being registered" do
    expect(StandardAudit.config.before_checksum_hooks).to be_empty
  end

  describe "two writers reading the same chain tip" do
    it "signs both rows against the same predecessor" do
      tip = create_log("committed.tip")

      first, second = build_concurrent_writers("concurrent.first", "concurrent.second")

      expect(first.checksum).to eq(first.compute_checksum_value(previous_checksum: tip.checksum))
      expect(second.checksum).to eq(second.compute_checksum_value(previous_checksum: tip.checksum))
    end

    it "leaves a chain that still verifies" do
      create_log("committed.tip")
      commit(build_concurrent_writers("concurrent.first", "concurrent.second"))

      result = described_class.verify_chain

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(3)
    end

    it "leaves a chain that still verifies when the table starts empty" do
      commit(build_concurrent_writers("genesis.first", "genesis.second"))

      result = described_class.verify_chain

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(2)
    end
  end

  describe "several writers in one request" do
    # The production signature: three audit events fired in immediate
    # succession within one request failed in identical counts (635 each).
    it "leaves a chain that still verifies" do
      create_log("committed.tip")
      commit(build_concurrent_writers("otp.requested", "otp.generated", "otp.sent"))

      result = described_class.verify_chain

      expect(result[:failures]).to be_empty
      expect(result[:valid]).to be true
      expect(result[:verified]).to eq(4)
    end
  end
end
