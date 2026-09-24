require "standard_audit/version"
require "standard_audit/engine"
require "standard_audit/configuration"
require "standard_audit/metadata_filter"
require "standard_audit/record_reference"
require "standard_audit/sensitive_keys_dry_run"
require "standard_audit/subscriber"
require "standard_audit/event_subscriber"
require "standard_audit/reference_preloading"
require "standard_audit/operation"
require "standard_audit/auditable"
require "standard_audit/audit_scope"
require "standard_audit/checks/retention"

module StandardAudit
  # Metadata keys owned internally by StandardAudit. Never filtered by
  # `sensitive_keys` even if a user adds them there.
  RESERVED_METADATA_KEYS = %w[_tags _source].freeze

  # Values of `entry[:via]` as `before_write` sees it:
  #
  # * `:direct` — `StandardAudit.record` without a block, and therefore
  #   `Auditable#record_audit` and `Operation#audit!`.
  # * `:notification` — the ActiveSupport::Notifications subscriber
  #   (`subscribe_to` patterns, and `StandardAudit.record` WITH a block, which
  #   instruments the event and lets this subscriber write it).
  # * `:rails_event` — the `Rails.event` subscriber (Rails 8.1+).
  VIA = %i[direct notification rails_event].freeze

  class << self
    # Applies configuration to the single mutable Configuration instance.
    #
    # `baseline: true` also *remembers* the block, so `reset_configuration!`
    # replays it. That matters because the config object holds behaviour, not
    # just data — `before_checksum_hooks` in particular. Without a baseline, a
    # suite that installs the rspec plugin (which calls `reset_configuration!`
    # before every example) silently loses write-time hooks after the first
    # example, and the specs that would notice pass vacuously.
    #
    # Idiomatic host usage, in config/initializers/standard_audit.rb:
    #
    #   StandardAudit.configure(baseline: true) do |config|
    #     config.subscribe_to "myapp.**"
    #     config.before_checksum :backfill_scope
    #   end
    #
    # Only the most recent `baseline: true` block is remembered; call it once,
    # from the initializer.
    def configure(baseline: false, &block)
      return config unless block

      @baseline_configuration = block if baseline
      block.call(config)
      config
    end

    def config
      @configuration ||= Configuration.new
    end

    # Writes one audit row. Every write path in the gem ends here — direct
    # calls, `Auditable#record_audit`, `Operation#audit!`, and both event
    # subscribers — so actor/scope resolution, `metadata_builder`,
    # `before_write`, redaction, batching and async all apply uniformly.
    #
    # Block form instruments `event_type` via ActiveSupport::Notifications
    # around the block and lets the Subscriber write the row (which lands back
    # here), so it records only when the event is subscribed to.
    #
    # `raise: false` makes a failed write non-fatal: the error is logged and
    # reported through `config.error_reporter` (default: `Rails.error`, as
    # handled), and nil is returned. For call
    # sites where a missing audit row must never break the request (auth
    # failure logging, say). It governs only the audit write — in block form
    # the subscriber already rescues, and the block's own errors always
    # propagate.
    def record(event_type, actor: nil, target: nil, scope: nil, metadata: {}, **options, &block)
      raise_errors = options.key?(:raise) ? options.delete(:raise) : true
      return unless config.enabled

      if block
        actor ||= config.current_actor_resolver.call
        # Nothing is built here: the Subscriber writes the row through
        # `write_entry`. Dereferencing a Relation now would load it eagerly,
        # before the block has run, purely to discard the result.
        ActiveSupport::Notifications.instrument(event_type, metadata.merge(
          actor: actor, target: target, scope: scope
        ), &block)
        return
      end

      begin
        write_entry(event_type, actor: actor, target: target, scope: scope,
          metadata: metadata, context: options, via: :direct)
      rescue => e
        raise if raise_errors

        report_write_error(e, event_type, source: "StandardAudit.record")
        nil
      end
    end

    # @api private — the single write path shared by `record` and the two
    # subscribers. Hosts call `record`.
    #
    # `context` carries explicit request_id/ip_address/user_agent/session_id
    # values; nil entries fall back to the Current resolvers. `reserved` is
    # merged into metadata AFTER `metadata_builder` (the Rails.event subscriber
    # uses it for `_tags` / `_source`, which a builder never saw before 0.12).
    # `via` names the entry point (see VIA) and is handed to `before_write`
    # as `entry[:via]`; it is not persisted.
    def write_entry(event_type, actor:, target:, scope:, metadata:, context: {}, reserved: {}, via: :direct)
      raise ArgumentError, "via must be one of #{VIA.inspect}; got #{via.inspect}" unless VIA.include?(via)

      actor ||= config.current_actor_resolver.call
      scope ||= config.current_scope_resolver&.call

      metadata = (metadata || {}).dup
      metadata = config.metadata_builder.call(metadata) if config.metadata_builder
      metadata = metadata.merge(reserved) if reserved.present?

      entry = {
        event_type: event_type,
        actor: actor,
        target: target,
        scope: scope,
        metadata: metadata,
        request_id: context[:request_id] || config.current_request_id_resolver.call,
        ip_address: context[:ip_address] || config.current_ip_address_resolver.call,
        user_agent: context[:user_agent] || config.current_user_agent_resolver.call,
        session_id: context[:session_id] || config.current_session_id_resolver.call,
        via: via
      }

      # Runs on EVERY path, AFTER `metadata_builder` and before redaction, so
      # it sees the builder's output and anything it injects into metadata is
      # still subject to `sensitive_keys` and dereferencing. It may mutate
      # `entry` in place; its return value is ignored. It may raise — that is
      # how a host guard rejects a write — and the error propagates exactly as
      # a failed save would. `entry[:via]` says which entry point wrote it.
      config.before_write&.call(entry)

      persist(entry)
    end

    # Buffers record calls and flushes them via insert_all! on block exit.
    # If the block raises, buffered records are dropped — only successful
    # batches are persisted. Nested batches flush independently.
    # Every write path buffers here, including events delivered by the
    # ActiveSupport::Notifications and Rails.event subscribers (the former
    # bypassed the buffer before 0.12.0). `before_write` runs before buffering,
    # and `before_checksum` hooks run at flush time, before each row's checksum
    # is computed — the same pipeline as a non-batched write.
    # Note: uses Thread.current for storage, which is not fiber-safe.
    # Apps using async adapters (Falcon) should avoid concurrent batches.
    def batch
      previous = Thread.current[:standard_audit_batch]
      buffer = Thread.current[:standard_audit_batch] = []

      yield

      flush_batch(buffer) if buffer.any?
    ensure
      Thread.current[:standard_audit_batch] = previous
    end

    # @api private — logs a failed audit write and reports it through
    # `report_error`. Used by the subscribers, which must never let an audit
    # failure break the instrumented code path, and by `record(raise: false)`.
    def report_write_error(error, event_type, **context)
      Rails.logger.error("[StandardAudit] Error creating audit log for #{event_type}: #{error.class}: #{error.message}")
      report_error(error, { config.audit_error_context_key => event_type, **context })
    end

    # @api private — the one place the gem reports an error it swallows.
    # Calls `config.error_reporter` when set, otherwise
    # `Rails.error.report(error, handled: true, context:)`. A reporter that
    # raises is logged and ignored.
    def report_error(error, context)
      if config.error_reporter
        config.error_reporter.call(error, context)
      elsif defined?(Rails) && Rails.respond_to?(:error) && Rails.error
        Rails.error.report(error, handled: true, context: context)
      end
      nil
    rescue => report_failure
      message = "[StandardAudit] Error reporting audit failure: #{report_failure.class}: #{report_failure.message}"
      Rails.logger&.error(message) if defined?(Rails) && Rails.respond_to?(:logger)
      nil
    end

    def subscriber
      @subscriber ||= Subscriber.new
    end

    def event_subscriber
      @event_subscriber ||= EventSubscriber.new
    end

    # Drops the memoized Configuration. Any block registered with
    # `configure(baseline: true)` is replayed onto the fresh instance, so a
    # per-example reset restores the app's real configuration rather than the
    # gem defaults.
    def reset_configuration!(replay_baseline: true)
      @configuration = nil
      @baseline_configuration&.call(config) if replay_baseline
      config
    end

    # Forgets the `configure(baseline: true)` block. Mainly for the gem's own
    # specs and for a host that needs a genuinely pristine configuration.
    def clear_baseline_configuration!
      @baseline_configuration = nil
    end

    def baseline_configured?
      !@baseline_configuration.nil?
    end

    private

    def persist(entry)
      actor = entry[:actor]
      target = entry[:target]
      scope = entry[:scope]

      # Redaction lives in MetadataFilter and record dereferencing in
      # RecordReference; both run here, once, for every write path.
      metadata = entry[:metadata] || {}
      metadata = RecordReference.call(metadata) if config.dereference_record_metadata
      metadata = MetadataFilter.call(metadata, config: config)

      attrs = {
        event_type: entry[:event_type],
        occurred_at: Time.current,
        request_id: entry[:request_id],
        ip_address: entry[:ip_address],
        user_agent: entry[:user_agent],
        session_id: entry[:session_id],
        metadata: metadata
      }

      gid_attrs = {
        actor_gid: actor&.to_global_id&.to_s,
        actor_type: actor&.class&.name,
        target_gid: target&.to_global_id&.to_s,
        target_type: target&.class&.name,
        scope_gid: scope&.to_global_id&.to_s,
        scope_type: scope&.class&.name
      }

      if batching?
        Thread.current[:standard_audit_batch] << attrs.merge(gid_attrs)
        nil
      elsif config.async
        StandardAudit::CreateAuditLogJob.perform_later(attrs.merge(gid_attrs).stringify_keys)
      else
        log = StandardAudit::AuditLog.new(attrs)
        log.actor = actor
        log.target = target
        log.scope = scope
        log.save!
        log
      end
    end

    def batching?
      Thread.current[:standard_audit_batch].is_a?(Array)
    end

    def flush_batch(buffer)
      now = Time.current
      records_parent = StandardAudit::AuditLog.chain_parent_column?
      previous_checksum = StandardAudit::AuditLog.chain_tip_checksum

      # Generate sorted UUIDs to ensure batch ordering matches id ordering.
      # UUIDv7 within the same millisecond can have non-monotonic lower bits;
      # sorting guarantees the chain order matches the id order used by
      # verify_chain. Under very high throughput this is a best-effort
      # guarantee — see compute_checksum's concurrency note.
      ids = buffer.size.times.map { SecureRandom.uuid_v7 }.sort

      rows = buffer.each_with_index.map do |attrs, i|
        row = StandardAudit::AuditLog.apply_before_checksum_hooks(attrs.merge(
          id: ids[i],
          created_at: now,
          updated_at: now
        ))
        checksum = StandardAudit::AuditLog.compute_checksum_value(
          row.stringify_keys,
          previous_checksum: previous_checksum
        )
        row[:previous_checksum] = previous_checksum if records_parent
        row[:checksum] = checksum
        previous_checksum = checksum
        row
      end

      StandardAudit::AuditLog.insert_all!(rows)
    end
  end
end
