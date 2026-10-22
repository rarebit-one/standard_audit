module StandardAudit
  # Records an authentication failure: a request refused before any operation
  # runs (an invalid or revoked token, a missing scope, a locked account). No
  # operation executes, so the operation audit contract (`audits` / `audit!`,
  # the catalogue) never sees these. The controller records them directly.
  # Extracted from three host copies (nutripod-web, luminality-web,
  # sidekick-web) of the same concern.
  #
  # In a controller, include the concern and call the private helper from your
  # `rescue_from` handlers:
  #
  #   class Api::BaseController < ActionController::API
  #     include StandardAudit::AuthFailure::Controller
  #   end
  #
  #   record_auth_failure("auth.token_invalid", "AUTH_001")
  #   record_auth_failure("auth.token_revoked", "AUTH_003", actor: session)
  #
  # Outside a controller (a hook that has the request but no controller of
  # yours), call the module directly:
  #
  #   StandardAudit::AuthFailure.record("auth.social_denied", "AUTH_009", request: request)
  #   StandardAudit::AuthFailure.record("auth.social_denied", "AUTH_009", path: "/auth/callback")
  #
  # == What lands in the row
  #
  # Metadata is an allow-list: `error_code`, `path`, `method` (when a request
  # is given), plus exactly the extra keywords the caller passes. Nothing is
  # read from params, headers or the exception message. This is the one path
  # where a live credential (the rejected token) is guaranteed to be in scope,
  # and audit rows are append-only, so callers must never pass it.
  # `sensitive_keys` redaction is the backstop, not the control.
  #
  # With a `request:`, the request id, IP and user agent go into the row's
  # columns explicitly, rather than through the Current resolvers, and the user
  # agent is truncated to USER_AGENT_LIMIT so an over-long header cannot make
  # the insert fail and cost the row.
  #
  # The actor is usually nil (authentication failed). A value that is not
  # GlobalID-able (a String, an id) is dropped rather than written.
  #
  # The write never raises (`raise: false`): the request is already being
  # refused, and an audit failure must not turn a 401 into a 500. Failed writes
  # go to `config.error_reporter` like any other non-raising record.
  #
  # With `config.log_auth_failures = true` each failure also emits one
  # structured `Rails.logger.warn` line, for alerting off the log stream.
  module AuthFailure
    # Hosts commonly cap `audit_logs.user_agent` at 1024 characters.
    USER_AGENT_LIMIT = 1024

    module_function

    # @return [StandardAudit::AuditLog, nil] the row, or nil when the write
    #   failed or auditing is disabled.
    def record(event_type, error_code, actor: nil, request: nil, path: nil, **extra_metadata)
      audit_actor = actor.respond_to?(:to_global_id) ? actor : nil
      path ||= request&.path

      log(event_type, error_code, actor, audit_actor, path, request, extra_metadata) if StandardAudit.config.log_auth_failures

      metadata = {
        "error_code" => error_code,
        "path" => path,
        "method" => request&.request_method,
        **extra_metadata.transform_keys(&:to_s)
      }.compact

      context = {}
      if request
        context[:request_id] = request.request_id
        context[:ip_address] = request.remote_ip
        context[:user_agent] = request.user_agent&.slice(0, USER_AGENT_LIMIT)
      end

      StandardAudit.record(event_type, actor: audit_actor, metadata: metadata, raise: false, **context.compact)
    end

    def log(event_type, error_code, actor, audit_actor, path, request, extra_metadata)
      return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Rails.logger.warn({
        event: event_type,
        error_code: error_code,
        path: path,
        ip: request&.remote_ip,
        actor: audit_actor ? audit_actor.to_global_id.to_s : actor&.to_s,
        timestamp: Time.now.utc.iso8601,
        **extra_metadata
      }.compact)
    end
    private_class_method :log

    # The controller concern. `record_auth_failure` is private, so it never
    # becomes an action.
    module Controller
      private

      def record_auth_failure(event_type, error_code, actor: nil, **extra_metadata)
        StandardAudit::AuthFailure.record(event_type, error_code, actor: actor, request: request, **extra_metadata)
      end
    end
  end
end
