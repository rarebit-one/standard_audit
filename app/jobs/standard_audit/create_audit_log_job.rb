module StandardAudit
  class CreateAuditLogJob < ActiveJob::Base
    queue_as { StandardAudit.config.queue_name }

    def perform(attrs)
      attrs = attrs.symbolize_keys

      actor_gid = attrs.delete(:actor_gid)
      target_gid = attrs.delete(:target_gid)
      scope_gid = attrs.delete(:scope_gid)
      actor_type = attrs.delete(:actor_type)
      target_type = attrs.delete(:target_type)
      scope_type = attrs.delete(:scope_type)

      log = StandardAudit::AuditLog.new(attrs)

      if actor_gid.present?
        begin
          log.actor = GlobalID::Locator.locate(actor_gid)
        rescue ActiveRecord::RecordNotFound
          log.actor_gid = actor_gid
          log.actor_type = actor_type
        end
      end

      if target_gid.present?
        begin
          log.target = GlobalID::Locator.locate(target_gid)
        rescue ActiveRecord::RecordNotFound
          log.target_gid = target_gid
          log.target_type = target_type
        end
      end

      if scope_gid.present?
        begin
          log.scope = GlobalID::Locator.locate(scope_gid)
        rescue ActiveRecord::RecordNotFound
          log.scope_gid = scope_gid
          log.scope_type = scope_type
        end
      end

      log.save!
    end
  end
end
