namespace :standard_audit do
  desc "Delete audit logs older than specified days (default: 90)"
  task :cleanup, [:days] => :environment do |_t, args|
    days = (args[:days] || StandardAudit.config.retention_days || 90).to_i
    cutoff = days.days.ago

    deleted = StandardAudit::AuditLog.where("occurred_at < ?", cutoff).delete_all
    puts "Deleted #{deleted} audit logs older than #{days} days"
  end

  desc "Archive audit logs to JSON file"
  task :archive, [:days, :output] => :environment do |_t, args|
    days = (args[:days] || 90).to_i
    output = args[:output] || "audit_logs_archive_#{Date.current}.json"
    cutoff = days.days.ago

    logs = StandardAudit::AuditLog.where("occurred_at < ?", cutoff)

    File.open(output, "w") do |f|
      logs.find_each do |log|
        f.puts log.attributes.to_json
      end
    end

    puts "Archived #{logs.count} logs to #{output}"
  end

  desc "Show audit log statistics"
  task stats: :environment do
    total = StandardAudit::AuditLog.count
    today = StandardAudit::AuditLog.today.count
    this_week = StandardAudit::AuditLog.this_week.count

    by_type = StandardAudit::AuditLog
      .group(:event_type)
      .order(count_all: :desc)
      .limit(10)
      .count

    puts "Audit Log Statistics"
    puts "===================="
    puts "Total: #{total}"
    puts "Today: #{today}"
    puts "This week: #{this_week}"
    puts ""
    puts "Top 10 Event Types:"
    by_type.each { |type, count| puts "  #{type}: #{count}" }
  end

  desc "Anonymize audit logs for a specific actor (GDPR right to erasure)"
  task :anonymize_actor, [:actor_gid] => :environment do |_t, args|
    raise "actor_gid is required" unless args[:actor_gid].present?

    count = StandardAudit::AuditLog.anonymize_actor!(args[:actor_gid])
    puts "Anonymized #{count} audit logs for #{args[:actor_gid]}"
  end

  desc "Export audit logs for a specific actor (GDPR right to access)"
  task :export_actor, [:actor_gid, :output] => :environment do |_t, args|
    raise "actor_gid is required" unless args[:actor_gid].present?
    output = args[:output] || "audit_export_#{Date.current}.json"

    data = StandardAudit::AuditLog.export_for_actor(args[:actor_gid])

    File.open(output, "w") do |f|
      f.puts JSON.pretty_generate(data)
    end

    puts "Exported #{data[:total_records]} audit logs to #{output}"
  end
end
