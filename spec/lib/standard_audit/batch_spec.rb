require "rails_helper"

RSpec.describe "StandardAudit.batch" do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:order) { Order.create!(total: 99.99) }

  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  after do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  it "inserts all records at once on block exit" do
    expect {
      StandardAudit.batch do
        StandardAudit.record("batch.first", actor: user, target: order, metadata: { n: 1 })
        StandardAudit.record("batch.second", actor: user, metadata: { n: 2 })

        # Records should not exist yet inside the block
        expect(StandardAudit::AuditLog.where(event_type: "batch.first").count).to eq(0)
      end
    }.to change(StandardAudit::AuditLog, :count).by(2)

    expect(StandardAudit::AuditLog.find_by(event_type: "batch.first")).to be_present
    expect(StandardAudit::AuditLog.find_by(event_type: "batch.second")).to be_present
  end

  it "preserves actor and target GIDs" do
    StandardAudit.batch do
      StandardAudit.record("batch.gid_test", actor: user, target: order)
    end

    log = StandardAudit::AuditLog.find_by(event_type: "batch.gid_test")
    expect(log.actor_gid).to eq(user.to_global_id.to_s)
    expect(log.actor_type).to eq("User")
    expect(log.target_gid).to eq(order.to_global_id.to_s)
    expect(log.target_type).to eq("Order")
  end

  it "assigns UUIDs to all records" do
    StandardAudit.batch do
      StandardAudit.record("batch.uuid1", actor: user)
      StandardAudit.record("batch.uuid2", actor: user)
    end

    logs = StandardAudit::AuditLog.where("event_type LIKE ?", "batch.uuid%")
    expect(logs.pluck(:id)).to all(match(/\A[0-9a-f-]{36}\z/))
    expect(logs.pluck(:id).uniq.size).to eq(2)
  end

  it "returns nil for each record call inside a batch" do
    result = nil
    StandardAudit.batch do
      result = StandardAudit.record("batch.return", actor: user)
    end

    expect(result).to be_nil
  end

  it "flushes nothing when batch is empty" do
    expect {
      StandardAudit.batch do
        # no records
      end
    }.not_to change(StandardAudit::AuditLog, :count)
  end

  it "does not interfere with non-batch records outside the block" do
    StandardAudit.batch do
      StandardAudit.record("batch.inside", actor: user)
    end

    log = StandardAudit.record("non.batch", actor: user)
    expect(log).to be_a(StandardAudit::AuditLog)
    expect(log).to be_persisted
  end

  it "filters sensitive keys in batch mode" do
    StandardAudit.batch do
      StandardAudit.record("batch.sensitive", actor: user, metadata: { action: "test", password: "secret123" })
    end

    log = StandardAudit::AuditLog.find_by(event_type: "batch.sensitive")
    expect(log.metadata).to include("action" => "test")
    expect(log.metadata).not_to have_key("password")
  end
end
