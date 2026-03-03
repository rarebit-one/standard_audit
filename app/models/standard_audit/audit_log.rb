module StandardAudit
  class AuditLog < ApplicationRecord
    self.table_name = "audit_logs"

    before_create :assign_uuid, if: -> { id.blank? }

    validates :event_type, presence: true
    validates :occurred_at, presence: true

    # -- Actor assignment via GlobalID --

    def actor=(record)
      if record.nil?
        self.actor_gid = nil
        self.actor_type = nil
      else
        self.actor_gid = record.to_global_id.to_s
        self.actor_type = record.class.name
      end
    end

    def actor
      return nil if actor_gid.blank?
      GlobalID::Locator.locate(actor_gid)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    # -- Target assignment via GlobalID --

    def target=(record)
      if record.nil?
        self.target_gid = nil
        self.target_type = nil
      else
        self.target_gid = record.to_global_id.to_s
        self.target_type = record.class.name
      end
    end

    def target
      return nil if target_gid.blank?
      GlobalID::Locator.locate(target_gid)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    # -- Scope assignment via GlobalID --

    def scope=(record)
      if record.nil?
        self.scope_gid = nil
        self.scope_type = nil
      else
        self.scope_gid = record.to_global_id.to_s
        self.scope_type = record.class.name
      end
    end

    def scope
      return nil if scope_gid.blank?
      GlobalID::Locator.locate(scope_gid)
    rescue ActiveRecord::RecordNotFound
      nil
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
    scope :chronological, -> { order(occurred_at: :asc) }
    scope :reverse_chronological, -> { order(occurred_at: :desc) }
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

    private

    def assign_uuid
      self.id = SecureRandom.uuid
    end
  end
end
