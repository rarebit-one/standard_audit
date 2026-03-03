module StandardAudit
  module AuditScope
    extend ActiveSupport::Concern

    def scoped_audit_logs
      StandardAudit::AuditLog.for_scope(self)
    end
  end
end
