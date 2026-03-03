module StandardAudit
  module Auditable
    extend ActiveSupport::Concern

    def audit_logs_as_actor
      StandardAudit::AuditLog.for_actor(self)
    end

    def audit_logs_as_target
      StandardAudit::AuditLog.for_target(self)
    end

    def audit_logs
      gid = to_global_id.to_s
      StandardAudit::AuditLog.where("actor_gid = ? OR target_gid = ?", gid, gid)
    end

    def record_audit(event_type, target: nil, scope: nil, metadata: {}, **options)
      StandardAudit.record(
        event_type,
        actor: self,
        target: target,
        scope: scope,
        metadata: metadata,
        **options
      )
    end
  end
end
