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

    # The event handler rescues so a failed audit write cannot break the
    # instrumented code path, but a log line alone is invisible to error
    # tracking — so it is reported as handled too.
    #
    # The write itself goes through StandardAudit.write_entry, the same path
    # `StandardAudit.record` uses, so batching, `current_scope_resolver`,
    # `metadata_builder` and `before_write` behave identically here. Until
    # 0.12.0 this method carried its own copy of the write logic, which ignored
    # `StandardAudit.batch`.
    def handle_event(event)
      config = StandardAudit.config
      return unless config.enabled

      payload = event.payload

      StandardAudit.write_entry(
        event.name,
        actor: config.actor_extractor.call(payload),
        target: config.target_extractor.call(payload),
        scope: config.scope_extractor.call(payload),
        metadata: payload.except(*EXCLUDED_PAYLOAD_KEYS),
        context: payload.slice(:request_id, :ip_address, :user_agent, :session_id)
      )
    rescue => e
      StandardAudit.report_write_error(e, event.name, subscriber: self.class.name)
    end

    EXCLUDED_PAYLOAD_KEYS = %i[actor target scope request_id ip_address user_agent session_id].freeze
    private_constant :EXCLUDED_PAYLOAD_KEYS
  end
end
