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

  desc "Verify audit log chain integrity (tamper detection)"
  task verify: :environment do
    result = StandardAudit::AuditLog.verify_chain

    puts "Audit Log Chain Verification"
    puts "============================="
    puts "Records verified: #{result[:verified]}"
    puts "Chain valid: #{result[:valid]}"
    puts "Forked links recovered: #{result[:recovered]}"

    if result[:failures].any?
      puts "\nUnverifiable records detected: #{result[:failures].size}"
      result[:failures].each do |failure|
        puts "  #{failure[:id]} (#{failure[:event_type]}) at #{failure[:created_at]} — #{failure[:reason]}"
      end
      abort "Chain verification failed"
    end
  end

  desc "Record the parent digest each existing row was signed against (never re-signs)"
  task relink_checksums: :environment do
    unless StandardAudit::AuditLog.chain_parent_column?
      abort "audit_logs has no previous_checksum column — run `rails generate standard_audit:add_previous_checksum` first"
    end

    result = StandardAudit::AuditLog.relink_checksums!

    puts "Relinked: #{result[:relinked]}"
    puts "Left as-is (already linked, or a segment root): #{result[:skipped]}"
    puts "Unresolved: #{result[:unresolved]}"
    puts ""
    puts "No checksum was rewritten. A parent is recorded only when it reproduces"
    puts "the digest the row has held since it was written; unresolved rows keep"
    puts "failing verification, which is the point."
  end

  desc "Backfill checksums for records that don't have them"
  task backfill_checksums: :environment do
    count = StandardAudit::AuditLog.backfill_checksums!
    puts "Backfilled checksums for #{count} audit log records"
  end

  namespace :sensitive_keys do
    desc "Report which historical metadata keys a redaction rule would strip (read-only)"
    task :dry_run, [:pattern] => :environment do |_t, args|
      # Audit rows are append-only, so a redaction rule that swallows real
      # content cannot be undone. This reads the rows you already have and
      # reports, per key, what the rule would have stripped.
      #
      #   rake standard_audit:sensitive_keys:dry_run
      #   rake "standard_audit:sensitive_keys:dry_run[secret]"
      #   NESTED=1 rake "standard_audit:sensitive_keys:dry_run[secret|token]"
      #
      # The argument is a Regexp source, matched case-insensitively, and is
      # applied *in addition to* the app's configured sensitive_keys.
      # NESTED=1/0 overrides config.filter_nested_metadata for the run.
      pattern = args[:pattern].presence || ENV["PATTERN"].presence
      patterns = StandardAudit.config.sensitive_key_patterns.dup
      patterns << Regexp.new(pattern, Regexp::IGNORECASE) if pattern

      nested =
        case ENV["NESTED"]
        when nil, "" then nil
        when "0", "false" then false
        else true
        end

      report = StandardAudit::SensitiveKeysDryRun.call(
        sensitive_key_patterns: patterns,
        nested: nested,
        batch_size: (ENV["BATCH_SIZE"] || 1000).to_i
      )

      puts "StandardAudit sensitive-key dry run"
      puts "==================================="
      puts "Candidate pattern: #{pattern ? Regexp.new(pattern, Regexp::IGNORECASE).inspect : '(none — reporting current config)'}"
      puts ""
      puts report
      puts ""
      puts "Nothing was written. Rows are append-only; a rule you enable applies only to future writes."
    end
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
