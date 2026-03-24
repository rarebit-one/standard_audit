module StandardAudit
  class CleanupJob < ActiveJob::Base
    queue_as { StandardAudit.config.queue_name }

    def perform
      days = StandardAudit.config.retention_days
      return unless days

      cutoff = days.days.ago
      StandardAudit::AuditLog.where("occurred_at < ?", cutoff).delete_all
    end
  end
end
