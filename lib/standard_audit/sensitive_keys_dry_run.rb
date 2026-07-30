require "set"

module StandardAudit
  # Answers "is this redaction rule safe for MY data?" against the rows an app
  # already has, before the rule is switched on.
  #
  # This matters more here than in most gems: audit rows are append-only, so a
  # rule that swallows real audit content cannot be undone after the fact — the
  # content is simply never written from then on. Reading the historical rows
  # first turns the judgement call into a command.
  #
  # Keys are extracted **in Ruby**, not with `jsonb_object_keys`, so this works
  # against SQLite (the dummy app), MySQL, and Postgres alike. The install
  # template's migration uses jsonb + GIN, but the gem itself stays
  # backend-neutral.
  #
  #   StandardAudit::SensitiveKeysDryRun.call(sensitive_key_patterns: [/secret/i])
  #   # => #<Report rows_scanned=1204 stripped={"client_secret"=>18, ...} ...>
  #
  class SensitiveKeysDryRun
    # [rows_scanned]        how many audit rows were read
    # [stripped]            key path => row count, for keys the candidate rule
    #                       would redact
    # [kept]                key path => row count, for keys it would keep
    # [nested_unfiltered]   key path => row count, for *nested* keys the rule
    #                       matches but which are NOT redacted because
    #                       `filter_nested_metadata` is off. This is the
    #                       exposure `filter_nested_metadata` exists to close;
    #                       empty when nested filtering is enabled.
    Report = Struct.new(:rows_scanned, :stripped, :kept, :nested_unfiltered, :nested, keyword_init: true) do
      def any_stripped?
        stripped.any?
      end

      def to_s
        lines = []
        lines << "Rows scanned: #{rows_scanned}"
        lines << "Nested filtering: #{nested ? 'on' : 'off'}"
        lines << ""

        lines << section("WOULD BE STRIPPED", stripped, "Nothing would be stripped.")
        lines << ""
        lines << section("KEPT", kept, "No metadata keys found.")

        if nested_unfiltered.any?
          lines << ""
          lines << section(
            "MATCHES BUT NOT STRIPPED (nested; set config.filter_nested_metadata = true to redact)",
            nested_unfiltered,
            nil
          )
        end

        lines.join("\n")
      end

      private

      def section(title, counts, empty_message)
        out = [title, "=" * title.length]

        if counts.empty?
          out << (empty_message || "None.")
        else
          width = counts.keys.map(&:length).max
          counts.sort_by { |key, count| [-count, key] }.each do |key, count|
            out << format("  %-#{width}s  %d row(s)", key, count)
          end
        end

        out.join("\n")
      end
    end

    class << self
      # Every keyword defaults to the app's live configuration, so calling it
      # with no arguments reports what the *current* config does.
      def call(sensitive_keys: nil, sensitive_key_patterns: nil, sensitive_key_exceptions: nil,
               nested: nil, relation: nil, batch_size: 1000)
        new(
          sensitive_keys: sensitive_keys,
          sensitive_key_patterns: sensitive_key_patterns,
          sensitive_key_exceptions: sensitive_key_exceptions,
          nested: nested
        ).call(relation: relation, batch_size: batch_size)
      end
    end

    def initialize(sensitive_keys: nil, sensitive_key_patterns: nil, sensitive_key_exceptions: nil, nested: nil)
      live = StandardAudit.config

      candidate = Configuration.new
      candidate.sensitive_keys = sensitive_keys || live.sensitive_keys
      candidate.sensitive_key_patterns = sensitive_key_patterns || live.sensitive_key_patterns
      candidate.sensitive_key_exceptions = sensitive_key_exceptions || live.sensitive_key_exceptions

      @nested = nested.nil? ? live.filter_nested_metadata : nested
      @filter = MetadataFilter.new(config: candidate)
    end

    def call(relation: nil, batch_size: 1000)
      relation ||= StandardAudit::AuditLog.all

      rows = 0
      stripped = Hash.new(0)
      kept = Hash.new(0)
      nested_unfiltered = Hash.new(0)

      relation.select(:id, :metadata).find_each(batch_size: batch_size) do |log|
        rows += 1
        metadata = log.metadata
        next unless metadata.respond_to?(:each_pair)

        # Collect distinct paths per row first, then increment once each. A row
        # whose `charges[]` array holds two matching hashes is ONE affected row,
        # not two — the counts are documented as row counts.
        row = { stripped: Set.new, kept: Set.new, nested_unfiltered: Set.new }
        walk(metadata, nil, row, top_level: true)

        row[:stripped].each { |path| stripped[path] += 1 }
        row[:kept].each { |path| kept[path] += 1 }
        row[:nested_unfiltered].each { |path| nested_unfiltered[path] += 1 }
      end

      Report.new(
        rows_scanned: rows,
        stripped: stripped,
        kept: kept,
        nested_unfiltered: nested_unfiltered,
        nested: @nested
      )
    end

    private

    def walk(hash, prefix, row, top_level:)
      hash.each_pair do |key, value|
        name = key.to_s
        path = prefix ? "#{prefix}.#{name}" : name

        # Reserved keys are immune at every depth, and their subtree is
        # gem-owned — never descended into. Mirrors MetadataFilter exactly, so
        # the dry run cannot misrepresent the rule it is modelling.
        if StandardAudit::RESERVED_METADATA_KEYS.include?(name)
          row[:kept] << path
          next
        end

        matches = @filter.filter?(name)

        if matches && (top_level || @nested)
          row[:stripped] << path
          next
        end

        # A nested match that survives because nested filtering is off. Reported
        # separately rather than silently counted as "kept" — this is exactly
        # the leak `filter_nested_metadata` closes.
        if matches
          row[:nested_unfiltered] << path
        else
          row[:kept] << path
        end

        descend(value, path, row)
      end
    end

    def descend(value, path, row)
      if value.respond_to?(:each_pair)
        walk(value, path, row, top_level: false)
      elsif value.is_a?(Array)
        value.each { |element| descend(element, "#{path}[]", row) }
      end
    end
  end
end
