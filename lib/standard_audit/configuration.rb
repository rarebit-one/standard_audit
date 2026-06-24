module StandardAudit
  class Configuration
    attr_accessor :async, :queue_name, :enabled,
                  :actor_extractor, :target_extractor, :scope_extractor,
                  :current_actor_resolver, :current_request_id_resolver,
                  :current_ip_address_resolver, :current_user_agent_resolver,
                  :current_session_id_resolver,
                  :sensitive_keys, :metadata_builder,
                  :anonymizable_metadata_keys, :retention_days

    def initialize
      @subscriptions = []
      @async = false
      @queue_name = :default
      @enabled = true

      @actor_extractor = ->(payload) { payload[:actor] }
      @target_extractor = ->(payload) { payload[:target] }
      @scope_extractor = ->(payload) { payload[:scope] }

      @current_actor_resolver = -> {
        defined?(Current) && Current.respond_to?(:user) ? Current.user : nil
      }
      @current_request_id_resolver = -> {
        defined?(Current) && Current.respond_to?(:request_id) ? Current.request_id : nil
      }
      @current_ip_address_resolver = -> {
        defined?(Current) && Current.respond_to?(:ip_address) ? Current.ip_address : nil
      }
      @current_user_agent_resolver = -> {
        defined?(Current) && Current.respond_to?(:user_agent) ? Current.user_agent : nil
      }
      @current_session_id_resolver = -> {
        defined?(Current) && Current.respond_to?(:session_id) ? Current.session_id : nil
      }

      # Note: :authorization filters the HTTP Authorization header value.
      # If you use "authorization" as a metadata key for policy decisions,
      # rename it (e.g. :authorization_policy) to avoid accidental filtering.
      @sensitive_keys = %i[
        password password_confirmation token secret
        api_key access_token refresh_token
        private_key certificate_chain
        ssn credit_card authorization
      ]
      @metadata_builder = nil
      @anonymizable_metadata_keys = %i[email name ip_address]

      # Retention defaults from ENV so it can be set per-environment without a
      # code change. Unset/blank/non-positive => nil (infinite retention, the
      # compliance-safe default that never auto-deletes). A host app can still
      # override with `config.retention_days = N` in its initializer.
      @retention_days = self.class.retention_days_from_env
    end

    # Parses STANDARD_AUDIT_RETENTION_DAYS into a positive Integer, or nil when
    # unset/blank/zero/negative/non-numeric (=> infinite retention).
    def self.retention_days_from_env
      raw = ENV["STANDARD_AUDIT_RETENTION_DAYS"]
      return nil if raw.nil? || raw.strip.empty?

      days = Integer(raw, exception: false)
      days&.positive? ? days : nil
    end

    def subscribe_to(pattern)
      @subscriptions << pattern
    end

    def subscriptions
      @subscriptions.dup.freeze
    end
  end
end
