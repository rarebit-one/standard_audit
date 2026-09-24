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
    def record(event_type, actor: nil, target: nil, scope: nil, metadata: {}, **options, &block)
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

      write_entry(event_type, actor: actor, target: target, scope: scope,
        metadata: metadata, context: options)
    end

    # @api private — the single write path shared by `record` and the two
    # subscribers. Hosts call `record`.
    #
    # `context` carries explicit request_id/ip_address/user_agent/session_id
    # values; nil entries fall back to the Current resolvers. `reserved` is
    # merged into metadata AFTER `metadata_builder` (the Rails.event subscriber
    # uses it for `_tags` / `_source`, which a builder never saw before 0.12).
    def write_entry(event_type, actor:, target:, scope:, metadata:, context: {}, reserved: {})
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
        session_id: context[:session_id] || config.current_session_id_resolver.call
      }

      # Runs on EVERY path, before redaction, so anything it injects into
      # metadata is still subject to `sensitive_keys` and dereferencing. It may
      # mutate `entry` in place; its return value is ignored. It may raise —
      # that is how a host guard rejects a write — and the error propagates
      # exactly as a failed save would.
      config.before_write&.call(entry)

      persist(entry)
    end

    # Buffers record calls and flushes them via insert_all! on block exit.
    # If the block raises, buffered records are dropped — only successful
    # batches are persisted. Nested batches flush independently.
    # Every write path buffers here, including events delivered by the
    # ActiveSupport::Notifications and Rails.event subscribers (the former
    # bypassed the buffer before 0.12.0). `before_write` runs before buffering;
    # `before_checksum` hooks do not run (insert_all! instantiates no model).
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

    # @api private — logs a failed audit write and reports it to Rails.error
    # as handled. Used by the subscribers, which must never let an audit
    # failure break the instrumented code path.
    def report_write_error(error, event_type, **context)
      Rails.logger.error("[StandardAudit] Error creating audit log for #{event_type}: #{error.class}: #{error.message}")
      return unless Rails.respond_to?(:error) && Rails.error

      Rails.error.report(
        error,
        handled: true,
        context: { config.audit_error_context_key => event_type, **context }
      )
    rescue => report_failure
      Rails.logger.error("[StandardAudit] Error reporting audit failure: #{report_failure.class}: #{report_failure.message}")
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
        row = attrs.merge(
          id: ids[i],
          created_at: now,
          updated_at: now
        )
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
