module StandardAudit
  # Subscriber for Rails 8.1+ structured event reporting (`Rails.event`).
  #
  # Registered with `Rails.event.subscribe(...)` so that every `Rails.event.notify`
  # call flows through StandardAudit for persistence. Events whose name does not
  # match any configured `subscribe_to` pattern are ignored.
  #
  # Payload is extracted with the same extractors used by the
  # ActiveSupport::Notifications subscriber. Rails.event `context` supplies
  # request_id/ip_address/user_agent/session_id and takes precedence over the
  # Current.* resolvers. Tags and source_location are captured as metadata
  # under the reserved keys `_tags` and `_source`.
  class EventSubscriber
    RESERVED_PAYLOAD_KEYS = %i[actor target scope request_id ip_address user_agent session_id].freeze

    def emit(event)
      return unless StandardAudit.config.enabled
      return unless matches_subscription?(event[:name])

      config  = StandardAudit.config
      payload = event[:payload] || {}
      context = event[:context] || {}
      tags    = event[:tags]    || {}

      actor  = config.actor_extractor.call(payload)
      target = config.target_extractor.call(payload)
      scope  = config.scope_extractor.call(payload)

      metadata = build_metadata(payload, tags, event[:source_location], config)

      StandardAudit.record(
        event[:name],
        actor: actor,
        target: target,
        scope: scope,
        metadata: metadata,
        request_id: context[:request_id] || payload[:request_id],
        ip_address: context[:ip_address] || payload[:ip_address],
        user_agent: context[:user_agent] || payload[:user_agent],
        session_id: context[:session_id] || payload[:session_id]
      )
    rescue => e
      Rails.logger.error("[StandardAudit] Error handling Rails.event: #{e.class}: #{e.message}")
    end

    private

    def matches_subscription?(name)
      StandardAudit.config.subscriptions.any? { |pattern| pattern_match?(pattern, name) }
    end

    # Supports the same pattern shapes as ActiveSupport::Notifications.subscribe:
    # a Regexp, or a String with `*` matching a single segment and `**` matching
    # the remainder.
    def pattern_match?(pattern, name)
      case pattern
      when Regexp
        pattern.match?(name)
      when String
        compiled_pattern_for(pattern).match?(name)
      else
        false
      end
    end

    def compiled_pattern_for(pattern)
      @pattern_cache ||= {}
      @pattern_cache[pattern] ||= Regexp.new(
        "\\A" + Regexp.escape(pattern).gsub('\\*\\*', ".*").gsub('\\*', "[^.]*") + "\\z"
      )
    end

    def build_metadata(payload, tags, source_location, config)
      reserved = RESERVED_PAYLOAD_KEYS.map(&:to_s)
      raw = payload.reject { |k, _| reserved.include?(k.to_s) }
      raw = config.metadata_builder.call(raw) if config.metadata_builder

      sensitive = config.sensitive_keys.map(&:to_s)
      cleaned = raw.reject { |k, _| sensitive.include?(k.to_s) }

      cleaned[:_tags] = tags if tags.is_a?(Hash) && tags.any?
      cleaned[:_source] = source_location if source_location
      cleaned
    end
  end
end
