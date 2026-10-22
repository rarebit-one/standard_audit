module StandardAudit
  class CleanupJob < ActiveJob::Base
    queue_as { StandardAudit.config.queue_name }

    def perform
      config = StandardAudit.config
      if config.retention_misconfigured?
        Rails.logger.warn("[StandardAudit] CleanupJob skipped: retention_days is #{config.retention_days.inspect}, " \
                          "not a positive Integer or :indefinite, so no audit logs were deleted")
        return
      end

      # nil and :indefinite both mean keep forever.
      days = config.retention_window_days
      return unless days

      cutoff = days.days.ago
      deleted = StandardAudit::AuditLog.before(cutoff).in_batches(of: 10_000).delete_all
      Rails.logger.info("[StandardAudit] CleanupJob deleted #{deleted} audit logs older than #{days} days")
    end
  end
end
