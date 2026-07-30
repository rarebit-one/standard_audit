module StandardAudit
  class Configuration
    attr_accessor :async, :queue_name, :enabled,
                  :actor_extractor, :target_extractor, :scope_extractor,
                  :current_actor_resolver, :current_request_id_resolver,
                  :current_ip_address_resolver, :current_user_agent_resolver,
                  :current_session_id_resolver,
                  :sensitive_keys, :sensitive_key_patterns,
                  :sensitive_key_exceptions, :filter_nested_metadata,
                  :metadata_builder,
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
      # Regexps matched against every metadata key name, in addition to the
      # exact-match `sensitive_keys` list. This is the supported way to catch a
      # family of keys: `/secret/i` redacts `client_secret`, `webhook_secret`,
      # and `secret` alike.
      #
      # There is deliberately NO substring *mode* for `sensitive_keys` — see
      # the note in MetadataFilter. Patterns are opt-in and per-app, which is
      # the only safe shape for a rule applied to append-only rows.
      @sensitive_key_patterns = []

      # Key names (String/Symbol, exact) or Regexps that are never redacted,
      # even when `sensitive_keys` or `sensitive_key_patterns` matches. Lets an
      # app adopt a broad pattern while keeping the handful of real audit keys
      # it would otherwise swallow, e.g.
      # `sensitive_key_patterns = [/token/i]` with
      # `sensitive_key_exceptions = %i[input_tokens output_tokens]`.
      @sensitive_key_exceptions = []

      # When true, redaction descends into nested Hashes (and Hashes inside
      # Arrays), so `metadata: { stripe: { client_secret: … } }` is caught.
      # Defaults to false: it changes what gets written, and audit rows are
      # append-only. Reserved keys are never descended into.
      @filter_nested_metadata = false

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
