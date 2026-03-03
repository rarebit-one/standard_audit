module StandardAudit
  class Subscriber
    attr_reader :subscriptions

    def initialize
      @subscriptions = []
    end

    def setup!
      config = StandardAudit.config
      config.subscriptions.each do |pattern|
        subscriber = ActiveSupport::Notifications.subscribe(pattern) do |event|
          handle_event(event)
        end
        @subscriptions << subscriber
      end
    end

    def teardown!
      @subscriptions.each do |subscriber|
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      @subscriptions.clear
    end

    private

    def handle_event(event)
      return unless StandardAudit.config.enabled

      config = StandardAudit.config
      payload = event.payload

      actor = config.actor_extractor.call(payload)
      target = config.target_extractor.call(payload)
      scope = config.scope_extractor.call(payload)

      # Fall back to Current attributes when payload values are nil
      actor ||= config.current_actor_resolver.call

      metadata = extract_metadata(payload, config)

      attrs = {
        event_type: event.name,
        occurred_at: Time.current,
        request_id: payload[:request_id] || config.current_request_id_resolver.call,
        ip_address: payload[:ip_address] || config.current_ip_address_resolver.call,
        user_agent: payload[:user_agent] || config.current_user_agent_resolver.call,
        session_id: payload[:session_id] || config.current_session_id_resolver.call,
        metadata: metadata
      }

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
      end
    rescue => e
      Rails.logger.error("[StandardAudit] Error creating audit log: #{e.message}")
    end

    def extract_metadata(payload, config)
      # Remove known non-metadata keys
      excluded_keys = %i[actor target scope request_id ip_address user_agent session_id]
      raw_metadata = payload.except(*excluded_keys)

      if config.metadata_builder
        raw_metadata = config.metadata_builder.call(raw_metadata)
      end

      # Filter sensitive keys
      sensitive = config.sensitive_keys.map(&:to_s)
      raw_metadata.reject { |k, _| sensitive.include?(k.to_s) }
    end
  end
end
