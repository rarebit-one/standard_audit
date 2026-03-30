require "standard_audit/version"
require "standard_audit/engine"
require "standard_audit/configuration"
require "standard_audit/subscriber"
require "standard_audit/auditable"
require "standard_audit/audit_scope"

module StandardAudit
  class << self
    def configure
      yield(config) if block_given?
    end

    def config
      @configuration ||= Configuration.new
    end

    def record(event_type, actor: nil, target: nil, scope: nil, metadata: {}, **options)
      return unless config.enabled

      actor ||= config.current_actor_resolver.call

      # Filter sensitive keys
      sensitive = config.sensitive_keys.map(&:to_s)
      filtered_metadata = metadata.reject { |k, _| sensitive.include?(k.to_s) }

      attrs = {
        event_type: event_type,
        occurred_at: Time.current,
        request_id: options[:request_id] || config.current_request_id_resolver.call,
        ip_address: options[:ip_address] || config.current_ip_address_resolver.call,
        user_agent: options[:user_agent] || config.current_user_agent_resolver.call,
        session_id: options[:session_id] || config.current_session_id_resolver.call,
        metadata: filtered_metadata
      }

      if block_given?
        # Block form: instrument via ActiveSupport::Notifications
        ActiveSupport::Notifications.instrument(event_type, metadata.merge(
          actor: actor, target: target, scope: scope
        )) do
          yield
        end
        return
      end

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

    def reset_configuration!
      @configuration = nil
    end

    private

    def batching?
      Thread.current[:standard_audit_batch].is_a?(Array)
    end

    def flush_batch(buffer)
      now = Time.current
      previous_checksum = StandardAudit::AuditLog
        .order(created_at: :desc, id: :desc)
        .limit(1)
        .pick(:checksum)

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
        row[:checksum] = checksum
        previous_checksum = checksum
        row
      end

      StandardAudit::AuditLog.insert_all!(rows)
    end
  end
end
