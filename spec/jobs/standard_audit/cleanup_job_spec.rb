require "rails_helper"

RSpec.describe StandardAudit::CleanupJob, type: :job do
  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  after do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  def create_log(occurred_at:)
    StandardAudit::AuditLog.create!(
      event_type: "test.event",
      occurred_at: occurred_at
    )
  end

  describe "#perform" do
    it "deletes logs older than retention_days" do
      StandardAudit.configure { |c| c.retention_days = 30 }

      old_log = create_log(occurred_at: 31.days.ago)
      recent_log = create_log(occurred_at: 29.days.ago)

      described_class.new.perform

      expect(StandardAudit::AuditLog.exists?(old_log.id)).to be false
      expect(StandardAudit::AuditLog.exists?(recent_log.id)).to be true
    end

    it "does nothing when retention_days is nil" do
      StandardAudit.configure { |c| c.retention_days = nil }

      log = create_log(occurred_at: 1000.days.ago)

      described_class.new.perform

      expect(StandardAudit::AuditLog.exists?(log.id)).to be true
    end

    it "logs the number of deleted records" do
      StandardAudit.configure { |c| c.retention_days = 30 }
      create_log(occurred_at: 31.days.ago)

      expect(Rails.logger).to receive(:info).with(/CleanupJob deleted .* audit logs older than 30 days/)
      described_class.new.perform
    end

    it "uses configured queue name" do
      StandardAudit.configure { |c| c.queue_name = :maintenance }

      job = described_class.new
      expect(job.queue_name).to eq("maintenance")
    end
  end
end
