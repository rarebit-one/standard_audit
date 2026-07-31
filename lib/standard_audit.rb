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

    def record(event_type, actor: nil, target: nil, scope: nil, metadata: {}, **options)
      return unless config.enabled

      actor ||= config.current_actor_resolver.call

      if block_given?
        # Block form: instrument via ActiveSupport::Notifications and let the
        # Subscriber write the row, which it does with its own dereferencing and
        # filtering. Nothing built below would be used, so it is not built —
        # dereferencing a Relation here would load it eagerly, before the block
        # has run, purely to discard the result.
        ActiveSupport::Notifications.instrument(event_type, metadata.merge(
          actor: actor, target: target, scope: scope
        )) do
          yield
        end
        return
      end

      # Redaction lives in MetadataFilter, shared with Subscriber, so the two
      # write paths cannot drift apart. Record dereferencing is applied on both
      # paths for the same reason: a snapshot of a whole row is as unrecoverable
      # here as it is on the notifications path.
      dereferenced = config.dereference_record_metadata ? RecordReference.call(metadata) : metadata
      filtered_metadata = MetadataFilter.call(dereferenced, config: config)

      attrs = {
        event_type: event_type,
        occurred_at: Time.current,
        request_id: options[:request_id] || config.current_request_id_resolver.call,
        ip_address: options[:ip_address] || config.current_ip_address_resolver.call,
        user_agent: options[:user_agent] || config.current_user_agent_resolver.call,
        session_id: options[:session_id] || config.current_session_id_resolver.call,
        metadata: filtered_metadata
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

    # Buffers record calls and flushes them via insert_all! on block exit.
    # If the block raises, buffered records are dropped — only successful
    # batches are persisted. Nested batches flush independently.
    # Block-form record calls (with AS::Notifications) bypass the buffer
    # and are processed normally since they don't persist records directly.
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
