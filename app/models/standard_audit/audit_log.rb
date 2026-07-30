require "openssl"

module StandardAudit
  class AuditLog < ApplicationRecord
    include StandardAudit::ReferencePreloading

    self.table_name = "audit_logs"

    CHECKSUM_FIELDS = %w[
      id event_type actor_gid actor_type target_gid target_type
      scope_gid scope_type metadata request_id ip_address
      user_agent session_id occurred_at
    ].freeze

    # Callback ORDER IS THE CONTRACT here. Definition order is execution
    # order, so registering the host hook list between assign_uuid and
    # compute_checksum means a hook can set a CHECKSUM_FIELDS member (e.g.
    # back-fill `scope`) and the row still verifies. Hosts previously had to
    # register `before_create ..., prepend: true` themselves to beat
    # compute_checksum — fragile ordering knowledge no host should need.
    # Do not reorder these three lines.
    before_create :assign_uuid, if: -> { id.blank? }
    before_create :run_before_checksum_hooks
    before_create :compute_checksum, if: -> { checksum.blank? }
    after_create_commit :emit_created_event

    # Audit logs are append-only. Use update_columns for privileged
    # operations like GDPR anonymization that must bypass this guard.
    # Note: delete/delete_all bypass callbacks and are permitted for
    # bulk cleanup operations (see CleanupJob, rake standard_audit:cleanup).
    before_update { raise ActiveRecord::ReadOnlyRecord }
    before_destroy { raise ActiveRecord::ReadOnlyRecord }

    validates :event_type, presence: true
    validates :occurred_at, presence: true

    # -- actor / target / scope assignment via GlobalID --
    #
    # Reads consult the preload memo first (see ReferencePreloading), then fall
    # back to a single `GlobalID::Locator.locate`. Writers populate the memo,
    # since they already hold the record. If the underlying record was deleted
    # the reader returns nil while the gid and type stay on the row.

    def actor=(record)
      assign_reference(:actor, record)
    end

    def actor
      read_reference(:actor)
    end

    def target=(record)
      assign_reference(:target, record)
    end

    def target
      read_reference(:target)
    end

    def scope=(record)
      assign_reference(:scope, record)
    end

    def scope
      read_reference(:scope)
    end

    # -- Query scopes --

    scope :for_actor, ->(record) { where(actor_gid: record.to_global_id.to_s) }
    scope :by_actor_type, ->(type) { where(actor_type: type.is_a?(Class) ? type.name : type.to_s) }
    scope :for_target, ->(record) { where(target_gid: record.to_global_id.to_s) }
    scope :by_target_type, ->(type) { where(target_type: type.is_a?(Class) ? type.name : type.to_s) }
    scope :for_scope, ->(record) { where(scope_gid: record.to_global_id.to_s) }
    scope :by_scope_type, ->(type) { where(scope_type: type.is_a?(Class) ? type.name : type.to_s) }
    scope :by_event_type, ->(event_type) { where(event_type: event_type) }
    scope :matching_event, ->(pattern) { where("event_type LIKE ?", pattern) }
    scope :between, ->(start_time, end_time) { where(occurred_at: start_time..end_time) }
    scope :since, ->(time) { where("occurred_at >= ?", time) }
    scope :before, ->(time) { where("occurred_at < ?", time) }
    scope :today, -> { where(occurred_at: Time.current.beginning_of_day..Time.current.end_of_day) }
    scope :yesterday, -> { where(occurred_at: 1.day.ago.beginning_of_day..1.day.ago.end_of_day) }
    scope :this_week, -> { where(occurred_at: Time.current.beginning_of_week..Time.current.end_of_week) }
    scope :this_month, -> { where(occurred_at: Time.current.beginning_of_month..Time.current.end_of_month) }
    scope :last_n_days, ->(n) { where("occurred_at >= ?", n.days.ago.beginning_of_day) }
    scope :for_request, ->(request_id) { where(request_id: request_id) }
    scope :from_ip, ->(ip_address) { where(ip_address: ip_address) }
    scope :for_session, ->(session_id) { where(session_id: session_id) }
    scope :chronological, -> { order(occurred_at: :asc, created_at: :asc) }
    scope :reverse_chronological, -> { order(occurred_at: :desc, created_at: :desc) }
    scope :recent, ->(n = 10) { reverse_chronological.limit(n) }

    # -- GDPR methods --

    def self.anonymize_actor!(record)
      gid = record.to_global_id.to_s
      logs = where("actor_gid = ? OR target_gid = ?", gid, gid)
      count = logs.count

      anonymizable_keys = StandardAudit.config.anonymizable_metadata_keys.map(&:to_s)

      logs.find_each do |log|
        attrs = {
          ip_address: nil,
          user_agent: nil,
          session_id: nil
        }

        attrs[:actor_gid] = "[anonymized]" if log.actor_gid == gid
        attrs[:actor_type] = "[anonymized]" if log.actor_gid == gid
        attrs[:target_gid] = "[anonymized]" if log.target_gid == gid
        attrs[:target_type] = "[anonymized]" if log.target_gid == gid

        if log.metadata.present? && anonymizable_keys.any?
          cleaned_metadata = log.metadata.reject { |k, _| anonymizable_keys.include?(k.to_s) }
          attrs[:metadata] = cleaned_metadata
        end

        log.update_columns(attrs)
      end

      count
    end

    def self.export_for_actor(record)
      gid = record.to_global_id.to_s
      logs = where("actor_gid = ? OR target_gid = ?", gid, gid).chronological

      records = logs.map do |log|
        {
          id: log.id,
          event_type: log.event_type,
          actor_gid: log.actor_gid,
          target_gid: log.target_gid,
          scope_gid: log.scope_gid,
          metadata: log.metadata,
          occurred_at: log.occurred_at.iso8601,
          ip_address: log.ip_address,
          user_agent: log.user_agent,
          request_id: log.request_id
        }
      end

      {
        subject: gid,
        exported_at: Time.current.iso8601,
        total_records: records.size,
        records: records
      }
    end

    # Recomputes the checksum from the record's current field values and the
    # given previous checksum. Useful for verification without saving.
    def compute_checksum_value(previous_checksum: nil)
      self.class.compute_checksum_value(
        attributes.slice(*CHECKSUM_FIELDS),
        previous_checksum: previous_checksum
      )
    end

    def self.compute_checksum_value(attrs, previous_checksum: nil)
      canonical = CHECKSUM_FIELDS.map { |f|
        value = attrs[f]
        value = value.to_json if value.is_a?(Hash)
        value = value.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ") if value.respond_to?(:strftime) && value.respond_to?(:utc)
        "#{f}=#{value}"
      }.join("|")

      canonical = "#{previous_checksum}|#{canonical}" if previous_checksum.present?

      OpenSSL::Digest::SHA256.hexdigest(canonical)
    end

    # Verifies the integrity of the audit log chain. Returns a result hash with
    # :valid (boolean), :verified (count), and :failures (array of hashes).
    #
    # Records are processed in (created_at, id) order. Records without a
    # checksum (pre-feature data) reset the chain — the next checksummed
    # record starts a new independent chain segment.
    def self.verify_chain(scope: nil, batch_size: 1000)
      relation = scope ? where(scope_gid: scope.to_global_id.to_s) : all

      previous_checksum = nil
      verified = 0
      failures = []

      relation.in_batches(of: batch_size) do |batch|
        batch.order(created_at: :asc, id: :asc).each do |record|
          if record.checksum.blank?
            previous_checksum = nil
            next
          end

          expected = record.compute_checksum_value(previous_checksum: previous_checksum)

          if record.checksum != expected
            failures << {
              id: record.id,
              event_type: record.event_type,
              created_at: record.created_at,
              expected: expected,
              actual: record.checksum
            }
          end

          verified += 1
          previous_checksum = record.checksum
        end
      end

      { valid: failures.empty?, verified: verified, failures: failures }
    end

    # Backfills checksums for records that don't have them (e.g. pre-existing
    # records before the checksum feature was added).
    def self.backfill_checksums!(batch_size: 1000)
      previous_checksum = nil
      count = 0

      in_batches(of: batch_size) do |batch|
        batch.order(created_at: :asc, id: :asc).each do |record|
          if record.checksum.present?
            previous_checksum = record.checksum
            next
          end

          new_checksum = compute_checksum_value(
            record.attributes.slice(*CHECKSUM_FIELDS),
            previous_checksum: previous_checksum
          )
          record.update_columns(checksum: new_checksum)

          previous_checksum = new_checksum
          count += 1
        end
      end

      count
    end

    private

    def emit_created_event
      ActiveSupport::Notifications.instrument("standard_audit.audit_log.created", {
        id: id,
        event_type: event_type,
        actor_type: actor_type,
        target_type: target_type,
        scope_type: scope_type
      })
    rescue StandardError => e
      Rails.logger.warn("[StandardAudit] Failed to emit event: #{e.class}: #{e.message}")
    end

    # Fetches the most recent record's checksum and chains the new record to it.
    # Note: concurrent inserts can read the same "previous" record, forking
    # the chain. Use database-level advisory locks if you need serializable
    # chain integrity under concurrent writes.
    def compute_checksum
      previous = self.class.order(created_at: :desc, id: :desc).limit(1).pick(:checksum)
      self.checksum = compute_checksum_value(previous_checksum: previous)
    end

    def assign_uuid
      self.id = SecureRandom.uuid_v7
    end

    # Runs config.before_checksum_hooks in registration order. Each hook is
    # rescued individually: an audit write must never fail because a host's
    # derived-column logic did. A hook that raises is rolled back to the
    # attributes it started from and skipped; the remaining hooks still run.
    def run_before_checksum_hooks
      hooks = StandardAudit.config.before_checksum_hooks
      return if hooks.blank?

      # Only relevant when a checksum was supplied explicitly (the normal path
      # has none yet, and compute_checksum runs next).
      checksummed_before = checksum.present? ? attributes.slice(*CHECKSUM_FIELDS) : nil

      hooks.each { |hook| run_before_checksum_hook(hook) }

      # A caller-supplied checksum stops describing the row the moment a hook
      # changes a checksummed field. Dropping it lets compute_checksum
      # re-derive one, rather than persisting a row that fails verify_chain
      # immediately. Hooks still run for such rows, because most derived
      # columns (actor_role and friends) are not checksummed at all.
      self.checksum = nil if checksummed_before && attributes.slice(*CHECKSUM_FIELDS) != checksummed_before
    end

    def run_before_checksum_hook(hook)
      snapshot = attributes.deep_dup

      begin
        case hook
        when Symbol, String then send(hook)
        else hook.call(self)
        end
      rescue StandardError => e
        # Roll the record back to where the hook found it. Without this a hook
        # that assigns scope_gid and then fails a later lookup leaves a
        # half-applied row that the following callbacks happily checksum and
        # persist — so the hook would not actually be "skipped".
        restore_attributes_from(snapshot)
        Rails.logger.warn("[StandardAudit] before_checksum hook failed: #{e.class}: #{e.message}")
        Rails.error.report(e, handled: true, context: { audit_event: event_type }) if Rails.respond_to?(:error)
        nil
      end
    end

    def restore_attributes_from(snapshot)
      snapshot.each do |name, value|
        write_attribute(name, value) unless read_attribute(name) == value
      end

      # The reference memo may hold a record the hook assigned; drop it so the
      # restored gid columns are the source of truth again.
      @preloaded_references = nil
    rescue StandardError => e
      Rails.logger.warn("[StandardAudit] could not roll back a failed before_checksum hook: #{e.class}: #{e.message}")
      nil
    end
  end
end
