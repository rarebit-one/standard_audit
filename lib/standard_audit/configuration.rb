module StandardAudit
  class Configuration
    attr_accessor :async, :queue_name, :enabled,
                  :actor_extractor, :target_extractor, :scope_extractor,
                  :current_actor_resolver, :current_request_id_resolver,
                  :current_ip_address_resolver, :current_user_agent_resolver,
                  :current_session_id_resolver,
                  :sensitive_keys, :sensitive_key_patterns,
                  :sensitive_key_exceptions, :filter_nested_metadata,
                  :metadata_builder, :before_checksum_hooks,
                  :anonymizable_metadata_keys, :retention_days,
                  :audit_catalogue, :verify_audit_declarations,
                  :raise_on_audit_write_error, :audit_write_error_handler

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

      # Callables (or Symbols naming an AuditLog instance method) run on
      # `before_create` AFTER the UUID is assigned and BEFORE the checksum is
      # computed. See Configuration#before_checksum.
      @before_checksum_hooks = []

      @anonymizable_metadata_keys = %i[email name ip_address]

      # ── StandardAudit::Operation (the operation-audit DSL) ────────────────

      # The host's canonical action vocabulary, used by `audit!` to reject an
      # action absent from it. Normally a CALLABLE, because referencing an
      # autoloadable constant eagerly from an initializer pins the first-loaded
      # copy and breaks Zeitwerk reloading:
      #
      #   config.audit_catalogue = -> { AuditCatalogue::ACTIONS }
      #
      # A plain Array is accepted when the vocabulary really is a frozen
      # literal. `nil` (the default) skips the membership check entirely, so
      # the DSL is adoptable before an app has a catalogue.
      #
      # Membership is the ONLY rule applied — see StandardAudit::Operation.
      @audit_catalogue = nil

      # Whether `audit!` verifies the declaration before writing. A callable
      # (or a plain boolean). Defaults to local environments only: in
      # production `audit!` just writes, because a developer's declaration
      # mistake must not 500 a user — the host's meta-spec is the real gate.
      @verify_audit_declarations = -> {
        defined?(Rails) && Rails.respond_to?(:env) && Rails.env.respond_to?(:local?) && Rails.env.local?
      }

      # Whether a failed audit *write* aborts the operation. `false` (report
      # and swallow) matches four of the five apps this DSL was extracted from.
      # Set `true` where an unaudited state change is itself a compliance
      # failure — one app deliberately does not rescue, and defaulting to
      # swallow would have silently downgraded that posture.
      #
      # StandardAudit::Operation::DeclarationError is NEVER governed by this;
      # it always propagates.
      @raise_on_audit_write_error = false

      # Optional callable invoked instead of the built-in logger/Rails.error
      # reporting when an audit write fails:
      #
      #   config.audit_write_error_handler =
      #     ->(error, action:, operation:) { ErrorReporting.notify(error, ...) }
      #
      # Runs before `raise_on_audit_write_error` is applied, so it sees every
      # write failure under either policy.
      @audit_write_error_handler = nil

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

    # Registers a hook to run between `assign_uuid` and `compute_checksum` on
    # every audit write that instantiates a model.
    #
    #   config.before_checksum { |log| log.scope = derive_scope(log) }
    #   config.before_checksum :backfill_organization_scope
    #
    # A hook may set a `CHECKSUM_FIELDS` member (`scope_gid`, `metadata`, …) and
    # the row will still verify, because the checksum is computed afterwards.
    # That is the whole point: before this existed, hosts had to register their
    # own `before_create ..., prepend: true` to beat the gem's checksum
    # callback, which is fragile ordering knowledge no host should need.
    #
    # Hooks accumulate and run in registration order. Each is rescued
    # individually — a failing hook logs and is skipped; it never fails the
    # audit write.
    #
    # A Symbol/String is sent to the AuditLog instance (use this for methods
    # supplied by a concern mixed into the model). A callable is passed the
    # instance.
    #
    # NOTE: batched writes (`StandardAudit.batch { … }` → `insert_all!`) never
    # instantiate a model, so hooks do not run there. A batched writer that
    # needs a derived column has to set it on the buffered attrs.
    def before_checksum(hook = nil, &block)
      hook ||= block
      raise ArgumentError, "before_checksum needs a callable, a Symbol, or a block" if hook.nil?

      @before_checksum_hooks << hook
      hook
    end

    def subscribe_to(pattern)
      @subscriptions << pattern
    end

    def subscriptions
      @subscriptions.dup.freeze
    end
  end
end
