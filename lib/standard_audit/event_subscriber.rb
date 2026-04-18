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

    def initialize
      @pattern_cache = {}
      @pattern_cache_mutex = Mutex.new
    end

    def emit(event)
      return unless StandardAudit.config.enabled

      name = event[:name]
      return if name.nil?
      return unless matches_subscription?(name)

      config  = StandardAudit.config
      payload = event[:payload] || {}
      context = event[:context] || {}

      actor  = config.actor_extractor.call(payload)
      target = config.target_extractor.call(payload)
      scope  = config.scope_extractor.call(payload)

      metadata = build_metadata(payload, event[:tags], event[:source_location], config)

      StandardAudit.record(
        name,
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
      cached = @pattern_cache[pattern]
      return cached if cached

      @pattern_cache_mutex.synchronize do
        @pattern_cache[pattern] ||= Regexp.new(
          "\\A" + Regexp.escape(pattern).gsub('\\*\\*', ".*").gsub('\\*', "[^.]*") + "\\z"
        )
      end
    end

    # `_tags` and `_source` are reserved metadata keys owned by this
    # subscriber. Sensitive-key filtering is handled downstream by
    # `StandardAudit.record`, so we don't re-run it here.
    def build_metadata(payload, tags, source_location, config)
      reserved = RESERVED_PAYLOAD_KEYS.map(&:to_s)
      raw = payload.reject { |k, _| reserved.include?(k.to_s) }
      raw = config.metadata_builder.call(raw) if config.metadata_builder

      if tags.is_a?(Hash) && tags.any?
        raw[:_tags] = tags
      elsif tags && !tags.is_a?(Hash)
        Rails.logger.warn("[StandardAudit] Dropping Rails.event tags of unexpected type: #{tags.class}")
      end
      raw[:_source] = source_location if source_location
      raw
    end
  end
end
