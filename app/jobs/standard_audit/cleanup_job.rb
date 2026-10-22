module StandardAudit
  class CleanupJob < ActiveJob::Base
    queue_as { StandardAudit.config.queue_name }

    def perform
      # nil and :indefinite both mean keep forever.
      days = StandardAudit.config.retention_window_days
      return unless days

      cutoff = days.days.ago
      deleted = StandardAudit::AuditLog.before(cutoff).in_batches(of: 10_000).delete_all
      Rails.logger.info("[StandardAudit] CleanupJob deleted #{deleted} audit logs older than #{days} days")
    end
  end
end
