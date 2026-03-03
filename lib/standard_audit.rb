require "standard_audit/version"
require "standard_audit/engine"
require "standard_audit/configuration"
require "standard_audit/subscriber"
require "standard_audit/auditable"
require "standard_audit/audit_scope"

module StandardAudit
  class << self
    def configure
      yield(config) if block_given?
    end

    def config
      @configuration ||= Configuration.new
    end

    def record(event_type, actor: nil, target: nil, scope: nil, metadata: {}, **options)
      return unless config.enabled

      actor ||= config.current_actor_resolver.call

      # Filter sensitive keys
      sensitive = config.sensitive_keys.map(&:to_s)
      filtered_metadata = metadata.reject { |k, _| sensitive.include?(k.to_s) }

      attrs = {
        event_type: event_type,
        occurred_at: Time.current,
        request_id: options[:request_id] || config.current_request_id_resolver.call,
        ip_address: options[:ip_address] || config.current_ip_address_resolver.call,
        user_agent: options[:user_agent] || config.current_user_agent_resolver.call,
        session_id: options[:session_id] || config.current_session_id_resolver.call,
        metadata: filtered_metadata
      }

      if block_given?
        # Block form: instrument via ActiveSupport::Notifications
        ActiveSupport::Notifications.instrument(event_type, metadata.merge(
          actor: actor, target: target, scope: scope
        )) do
          yield
        end
        return
      end

      if config.async
        job_attrs = attrs.dup
        job_attrs[:actor_gid] = actor&.to_global_id&.to_s
        job_attrs[:target_gid] = target&.to_global_id&.to_s
        job_attrs[:scope_gid] = scope&.to_global_id&.to_s
        job_attrs[:actor_type] = actor&.class&.name
        job_attrs[:target_type] = target&.class&.name
        job_attrs[:scope_type] = scope&.class&.name
        StandardAudit::CreateAuditLogJob.perform_later(job_attrs.stringify_keys)
      else
        log = StandardAudit::AuditLog.new(attrs)
        log.actor = actor
        log.target = target
        log.scope = scope
        log.save!
        log
      end
    end

    def subscriber
      @subscriber ||= Subscriber.new
    end

    def reset_configuration!
      @configuration = nil
    end
  end
end
