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

    # `subject` may be a record, a GlobalID, or a GlobalID string
    # ("gid://app/User/1"). A string is parsed, never located, so erasure and
    # export still work after the subject's own row has been deleted.
    #
    # Anonymization rewrites CHECKSUM_FIELDS, so an anonymized row can no
    # longer reproduce its own digest. Its stored `checksum` is deliberately
    # left untouched, so the rows after it still link to it. When the host has
    # the `anonymized_at` column (`standard_audit:add_anonymized_at`), the row
    # is stamped and `verify_chain` counts it as `redacted` rather than as a
    # `digest_mismatch` failure. Without the column, anonymization works
    # exactly as before and such rows still fail verification.
    def self.anonymize_actor!(subject)
      gid = subject_gid_for(subject)
      logs = where("actor_gid = ? OR target_gid = ?", gid, gid)
      count = logs.count

      anonymizable_keys = StandardAudit.config.anonymizable_metadata_keys.map(&:to_s)
      stamp = anonymization_column? ? Time.current : nil

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

        attrs[:anonymized_at] = log.anonymized_at || stamp if stamp

        log.update_columns(attrs)
      end

      count
    end

    # True when the table carries `anonymized_at` (the
    # `standard_audit:add_anonymized_at` migration, or a 0.12+ install).
    def self.anonymization_column?
      column_names.include?("anonymized_at")
    end

    # True when this row's checksummed fields were rewritten by
    # `anonymize_actor!`, so its digest is unverifiable by construction.
    def anonymized?
      has_attribute?(:anonymized_at) && anonymized_at.present?
    end

    def self.export_for_actor(subject)
      gid = subject_gid_for(subject)
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

    # Normalises a GDPR subject to its GlobalID string. Parses rather than
    # locates, so it works when the subject's row no longer exists.
    def self.subject_gid_for(subject)
      gid =
        case subject
        when GlobalID then subject
        when String then GlobalID.parse(subject)
        else subject.respond_to?(:to_global_id) ? subject.to_global_id : nil
        end

      raise ArgumentError, "expected a record, a GlobalID, or a GlobalID string (gid://app/Model/id), got #{subject.inspect}" unless gid

      gid.to_s
    end
    private_class_method :subject_gid_for

    # Recomputes the checksum from the record's current field values and the
    # given previous checksum. Useful for verification without saving.
    # The algorithm (StandardAudit::Checksum::LEGACY or CANONICAL) follows the
    # row's `created_at` against `config.canonical_checksum_since`; pass
    # `version:` to force one.
    def compute_checksum_value(previous_checksum: nil, version: nil)
      self.class.compute_checksum_value(
        attributes.slice(*CHECKSUM_FIELDS),
        previous_checksum: previous_checksum,
        version: version || StandardAudit::Checksum.algorithm_for(created_at)
      )
    end

    # `attrs` may carry "created_at" / :created_at, which picks the algorithm
    # as for a stored row; without it, the algorithm a write now would use.
    def self.compute_checksum_value(attrs, previous_checksum: nil, version: nil)
      version ||= StandardAudit::Checksum.algorithm_for(attrs["created_at"] || attrs[:created_at])

      StandardAudit::Checksum.digest(
        attrs,
        fields: CHECKSUM_FIELDS,
        previous_checksum: previous_checksum,
        version: version
      )
    end

    # Runs the configured `before_checksum` hooks against a row that will be
    # written by `insert_all!` (the `StandardAudit.batch` flush), so batched
    # writes get the same derived columns as a `save!`. The row is loaded into
    # an unsaved instance, the hooks run exactly as on `before_create`, and the
    # resulting attributes are returned for checksumming. With no hooks
    # registered the row is returned untouched and no model is built.
    def self.apply_before_checksum_hooks(row)
      return row if StandardAudit.config.before_checksum_hooks.blank?

      log = new(row)
      log.send(:run_before_checksum_hooks)
      log.attributes.symbolize_keys.except(:checksum, :previous_checksum)
    end

    # The checksum of the most recent row — the node a new row links to.
    def self.chain_tip_checksum
      order(created_at: :desc, id: :desc).limit(1).pick(:checksum)
    end

    # True when the table carries the `previous_checksum` column, i.e. the host
    # has run the `standard_audit:add_previous_checksum` migration. Rows written
    # without it are verified by position and parent recovery instead, so the
    # gem keeps working unmigrated.
    def self.chain_parent_column?
      column_names.include?("previous_checksum")
    end

    # Verifies the integrity of the audit log. Returns a result hash:
    #
    #   valid:               true when :failures is empty (see "Legacy rows")
    #   verified:            rows whose digest was checked (every checksummed,
    #                        non-anonymized row)
    #   recovered:           rows verified against a searched-for parent
    #   reordered:           legacy rows verified by reconstructing the
    #                        metadata key order they were signed with
    #   redacted:            anonymized rows (not digest-checked)
    #   legacy_unverifiable: count of :unverifiable
    #   unverifiable:        legacy rows whose digest can't be reproduced
    #                        because the key order they were signed with is
    #                        lost — same shape as a failure, reason
    #                        :legacy_key_order_unverifiable
    #   failures:            hashes with :id, :event_type, :created_at,
    #                        :expected, :actual and :reason
    #
    # == Checksum algorithms and the cutover
    #
    # A row created at or after `config.canonical_checksum_since` (default
    # StandardAudit::CANONICAL_CHECKSUM_CUTOVER) is signed with the canonical
    # digest, which does not depend on how the database orders JSON object
    # keys, and is verified STRICTLY with it: a mismatch is :digest_mismatch,
    # never a legacy classification. An earlier row is legacy: its digest
    # hashed `metadata.to_json` in Ruby insertion order, which `jsonb`
    # discards (fundbright/delivery-ops#689). See StandardAudit::Checksum.
    # The decision is recomputed from each row's stored `created_at`, the
    # same value the writer used.
    #
    # == Legacy rows
    #
    # A legacy row is checked with the legacy digest, exactly as before —
    # declared parent, else the preceding row, else the recovery search
    # below. One that still does not reproduce is, in this order:
    #
    #   1. searched for the metadata key order it was signed with. A key order
    #      that reproduces the stored digest is a witness, like the parent
    #      search; the row counts in :reordered and is valid. Bounded by
    #      `key_order_search_limit` orderings per row
    #      (Checksum::KeyOrderSearch), against the declared parent or else the
    #      preceding row and "no parent";
    #   2. reported `:digest_mismatch` when that search was EXHAUSTIVE against
    #      the parent the row declares (no key order explains it), or when the
    #      row has no JSON object with more than one key (key order cannot be
    #      why it fails);
    #   3. reported `:missing_parent` when its declared parent is absent;
    #   4. otherwise listed in :unverifiable with reason
    #      `:legacy_key_order_unverifiable`.
    #
    # `:legacy_key_order_unverifiable` means "cannot be proven either way":
    # an edited legacy row looks exactly like one whose key order was lost.
    # Such rows do NOT make `valid` false on their own — the gem cannot tell,
    # and the policy for them belongs to the host — but they are never
    # silent: they are counted in :legacy_unverifiable and listed in
    # :unverifiable. Pass `fail_on_legacy_unverifiable: true` to report them
    # as failures instead. After the cutover no new legacy row can be
    # written, so under honest operation :legacy_unverifiable never grows;
    # alert if it does (an edited pre-cutover row, or a `created_at` moved
    # back across the cutover).
    #
    # A row stamped `anonymized_at` (GDPR erasure via `anonymize_actor!`) is
    # counted in :redacted instead of being digest-checked: its checksummed
    # fields were rewritten on purpose, so its digest cannot reproduce. Its
    # stored checksum is unchanged, so the rest of the chain still links
    # through it, and a declared parent is still checked for presence. Treat a
    # nonzero :redacted as something to reconcile against your erasure
    # records — anyone able to write `anonymized_at` can also hide an edit
    # behind it.
    #
    # Records are processed in (created_at, id) order. Records without a
    # checksum (pre-feature data) reset the walk — the next checksummed record
    # starts a new independent segment.
    #
    # The log is a DAG, not a strict line. Concurrent writers link to whichever
    # node was the tip when they read it, so two rows can share a parent and
    # the sequence forks. Every row is still verified against the exact digest
    # it signed, in one of two ways:
    #
    #   * `previous_checksum` present (written by 0.8+ on a migrated host): the
    #     parent the writer asserts. It is covered by this row's own digest, so
    #     it cannot be edited to excuse a tampered row.
    #   * `previous_checksum` NULL (pre-0.8 rows, or an unmigrated host): the
    #     preceding row in the walk, and — unless `strict:` — a search back
    #     through the last `recovery_window` digests (and finally "no parent at
    #     all", for a row written against an empty table) for the one that
    #     actually reproduces this row's checksum. That recovers the true parent
    #     of a forked row without re-signing anything. It does not weaken tamper
    #     detection: a row whose fields were altered reproduces no candidate's
    #     digest, so it still fails. (The key-order search is not combined with
    #     this window search, so a legacy row that was both forked and
    #     reordered stays unverifiable.)
    #
    # The chain links across the cutover like anywhere else: the first
    # canonical row's parent is the last legacy row's stored checksum.
    #
    # A row whose parent digest is absent from the log is reported with
    # `reason: :missing_parent` — a row was removed. Two exemptions:
    #
    #   * `scope:` — the log is global, so a scoped row's parent usually
    #     belongs to another scope and is absent for an innocent reason.
    #   * a pruned start. If the walk *opens* on a row whose parent is already
    #     gone, the log has had its start removed (retention cleanup). That
    #     parent digest is then exempt wherever else it appears, because a
    #     pruned row can have several children — which is exactly what a
    #     concurrent append leaves behind. Removing a row from the middle is
    #     still reported: its digest is not the one the walk opened on.
    #
    # `standard_audit:cleanup` prunes by `occurred_at` while the walk orders by
    # `created_at`. Rows whose two timestamps disagree (a backdated
    # `occurred_at`) can leave a hole rather than a prefix, and a hole is
    # reported — truthfully, since rows really are missing.
    def self.verify_chain(scope: nil, batch_size: 1000, recovery_window: 256, strict: false,
      key_order_search_limit: StandardAudit::Checksum::KeyOrderSearch::DEFAULT_LIMIT,
      fail_on_legacy_unverifiable: false)
      relation = scope ? where(scope_gid: scope.to_global_id.to_s) : all
      check_parents = scope.nil?
      declared_parents = chain_parent_column?
      key_orders = StandardAudit::Checksum::KeyOrderSearch.new(limit: key_order_search_limit)

      previous_checksum = nil
      verified = 0
      recovered = 0
      reordered = 0
      redacted = 0
      unverifiable = []
      failures = []
      window = []
      first_row = true
      pruned_parents = []

      # Records a :missing_parent failure when `declared` is absent from the
      # log, unless the walk opened on it (a pruned start). True when reported.
      report_missing_parent = lambda do |record, declared, expected|
        next false unless declared.present? && check_parents && !parent_present?(declared, window, relation)

        if first_row
          # The walk opens on a row whose parent is already gone, so the log
          # has had its start removed — retention pruning, typically. That
          # parent is unknowable, and it can have several children (which is
          # what a concurrent append leaves behind), so the exemption is
          # remembered per digest rather than for one row.
          pruned_parents << declared
          false
        elsif pruned_parents.include?(declared)
          false
        else
          failures << chain_failure(record, expected: expected, reason: :missing_parent)
          true
        end
      end

      each_in_chain_order(relation, batch_size: batch_size) do |record|
        if record.checksum.blank?
          previous_checksum = nil
          window.clear
          next
        end

        declared = declared_parents ? record.previous_checksum : nil

        if record.anonymized?
          redacted += 1
          # The digest cannot be checked, but the parent it declares can.
          report_missing_parent.call(record, declared, nil)
        else
          verified += 1
          algorithm = StandardAudit::Checksum.algorithm_for(record.created_at)
          parent = declared.presence || previous_checksum
          expected = walk_digester(record, algorithm).call(parent)

          if record.checksum == expected
            # Links to its declared parent, or to the row before it as a
            # linear chain does.
            report_missing_parent.call(record, declared, expected)
          elsif declared.blank? && !strict && recover_parent(record, window, algorithm)
            recovered += 1
          elsif algorithm == StandardAudit::Checksum::LEGACY && legacy_key_order_ambiguous?(record)
            attrs = record.attributes.slice(*CHECKSUM_FIELDS)
            parents = declared.present? || strict ? [parent] : [parent, nil].uniq

            if key_orders.search(attrs, fields: CHECKSUM_FIELDS, checksum: record.checksum, parents: parents)
              reordered += 1
              # The row verified under a reconstructed order, so the stored-
              # order `expected` means nothing for a missing-parent report.
              report_missing_parent.call(record, declared, nil)
            elsif declared.present? && key_orders.exhaustive?(attrs, fields: CHECKSUM_FIELDS)
              # Every key order was tried against the parent the row itself
              # declares, so key order does not explain this row.
              failures << chain_failure(record, expected: expected, reason: :digest_mismatch)
            elsif report_missing_parent.call(record, declared, nil)
              # Reported as a removed row, which is the stronger finding. No
              # `expected`: no digest was established for this row.
            else
              entry = chain_failure(record, expected: expected, reason: :legacy_key_order_unverifiable)
              unverifiable << entry
              failures << entry if fail_on_legacy_unverifiable
            end
          else
            failures << chain_failure(record, expected: expected, reason: :digest_mismatch)
          end
        end

        previous_checksum = record.checksum
        first_row = false
        window << record.checksum
        window.shift if window.size > recovery_window
      end

      {
        valid: failures.empty?,
        verified: verified,
        recovered: recovered,
        reordered: reordered,
        redacted: redacted,
        legacy_unverifiable: unverifiable.size,
        unverifiable: unverifiable,
        failures: failures
      }
    end

    # Records, for every row that does not already carry one, the parent digest
    # it was actually signed against — recovering it by search where a
    # concurrent append forked the chain. Returns
    # `{ relinked:, unresolved:, skipped: }`.
    #
    # This NEVER rewrites a `checksum`. It writes only the previously-empty
    # `previous_checksum` column, so it adds no attestation the rows did not
    # already carry: a parent is recorded only when it reproduces the digest
    # the row has held since it was written. Rows whose parent cannot be
    # reproduced are left untouched and counted in :unresolved — they are the
    # rows verification should keep reporting.
    def self.relink_checksums!(batch_size: 1000, recovery_window: 256)
      return { relinked: 0, unresolved: 0, skipped: 0 } unless chain_parent_column?

      previous_checksum = nil
      relinked = 0
      unresolved = 0
      skipped = 0
      window = []

      each_in_chain_order(all, batch_size: batch_size) do |record|
        if record.checksum.blank?
          previous_checksum = nil
          window.clear
          next
        end

        found = resolve_parent(record, previous_checksum, window) if record.previous_checksum.blank?

        if record.previous_checksum.present?
          skipped += 1
        elsif found.nil?
          unresolved += 1
        elsif found.first.present?
          record.update_columns(previous_checksum: found.first)
          relinked += 1
        else
          # A genuine segment root. NULL already says so; nothing to write.
          skipped += 1
        end

        previous_checksum = record.checksum
        window << record.checksum
        window.shift if window.size > recovery_window
      end

      { relinked: relinked, unresolved: unresolved, skipped: skipped }
    end

    def self.chain_failure(record, expected:, reason:)
      {
        id: record.id,
        event_type: record.event_type,
        created_at: record.created_at,
        expected: expected,
        actual: record.checksum,
        reason: reason
      }
    end
    private_class_method :chain_failure

    # Searches `window` (most recent first, then "no parent at all") for the
    # digest that reproduces the record's stored checksum under `algorithm`.
    # Returns a one-element array holding the parent — which may
    # itself be nil, for a row written against an empty table — or nil when
    # nothing reproduces the digest.
    #
    # SHA-256 preimage resistance is what makes this safe: a row whose fields
    # were altered reproduces no candidate's digest, so it is still reported.
    def self.recover_parent(record, window, algorithm)
      window.reverse_each do |candidate|
        return [candidate] if digest_matches?(record, candidate, algorithm)
      end

      [nil] if digest_matches?(record, nil, algorithm)
    end
    private_class_method :recover_parent

    def self.resolve_parent(record, previous_checksum, window)
      algorithm = StandardAudit::Checksum.algorithm_for(record.created_at)
      return [previous_checksum] if digest_matches?(record, previous_checksum, algorithm)

      recover_parent(record, window, algorithm)
    end
    private_class_method :resolve_parent

    def self.digest_matches?(record, parent, algorithm)
      record.checksum == walk_digester(record, algorithm).call(parent)
    end
    private_class_method :digest_matches?

    # The row's `parent -> digest` function for `algorithm`, memoised on the
    # loaded record: the parent searches try hundreds of parents per row, and
    # this makes each try one SHA-256 instead of re-serialising the row. Only
    # for records the walk loaded and never mutates.
    def self.walk_digester(record, algorithm)
      memo = record.instance_variable_get(:@walk_digesters) || record.instance_variable_set(:@walk_digesters, {})
      memo[algorithm] ||= StandardAudit::Checksum.digester(
        record.attributes.slice(*CHECKSUM_FIELDS), fields: CHECKSUM_FIELDS, version: algorithm
      )
    end
    private_class_method :walk_digester

    # True when the row's hashed JSON could have been reordered by the store:
    # some object in it has more than one key.
    def self.legacy_key_order_ambiguous?(record)
      CHECKSUM_FIELDS.any? { |f| StandardAudit::Checksum.key_order_ambiguous?(record[f]) }
    end
    private_class_method :legacy_key_order_ambiguous?

    def self.parent_present?(digest, window, relation)
      window.include?(digest) || relation.exists?(checksum: digest)
    end
    private_class_method :parent_present?

    # Backfills checksums for records that don't have them (e.g. pre-existing
    # records before the checksum feature was added).
    def self.backfill_checksums!(batch_size: 1000)
      previous_checksum = nil
      count = 0

      each_in_chain_order(all, batch_size: batch_size) do |record|
        if record.checksum.present?
          previous_checksum = record.checksum
          next
        end

        # The row's own created_at picks the algorithm, as verification will.
        new_checksum = record.compute_checksum_value(previous_checksum: previous_checksum)
        columns = { checksum: new_checksum }
        columns[:previous_checksum] = previous_checksum if chain_parent_column?
        record.update_columns(columns)

        previous_checksum = new_checksum
        count += 1
      end

      count
    end

    # Yields every record of `relation` in true (created_at, id) order, loading
    # at most `batch_size` rows at a time via a keyset cursor.
    #
    # `in_batches` cannot do this, and used to be used here: it paginates by
    # PRIMARY KEY range and applies any ordering only *within* each batch, so
    # the global sequence it yields is a concatenation of id-ranges, each
    # internally time-sorted. With the UUIDv7 ids `assign_uuid` generates that
    # usually coincides with insertion order, which is why it went unnoticed —
    # but it is wrong for any host that assigns ids differently, backfills rows
    # with an explicit created_at, or has clock skew between writers. The chain
    # is an ordering claim, so a verifier that walks a different order than the
    # one it documents cannot be trusted to prove or disprove anything about it.
    #
    # The cursor predicate assumes created_at is NOT NULL, which the install
    # migration's `t.timestamps` guarantees. A NULL created_at would compare as
    # NULL and end the walk early rather than loop forever.
    def self.each_in_chain_order(relation, batch_size: 1000)
      cursor = nil

      loop do
        page = relation.reorder(created_at: :asc, id: :asc).limit(batch_size)

        if cursor
          page = page.where(
            "created_at > :created_at OR (created_at = :created_at AND id > :id)",
            created_at: cursor.first, id: cursor.last
          )
        end

        records = page.to_a
        break if records.empty?

        records.each { |record| yield record }
        break if records.size < batch_size

        cursor = [records.last.created_at, records.last.id]
      end
    end
    private_class_method :each_in_chain_order

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

    # Links the new record to whichever row was the chain tip when this writer
    # read it, and RECORDS WHICH ONE THAT WAS.
    #
    # The tip read is deliberately unlocked. Two concurrent transactions cannot
    # see each other's uncommitted rows, so both may read the same tip and the
    # sequence forks — that is not an error, it is what a multi-process writer
    # does, and it is why 67% of one production log failed verification while
    # the rows themselves were untampered (fundbright/delivery-ops#433). The
    # alternative is a lock held until the *enclosing business transaction*
    # commits (a row is invisible to other writers until then, so releasing
    # earlier reopens the race), which would serialise every audited request in
    # the estate behind one mutex. Recording the parent instead makes the fork
    # verifiable rather than preventing it.
    #
    # `previous_checksum` needs no protection of its own: it is an input to
    # this row's own digest, so editing it invalidates the row.
    #
    # The algorithm is chosen from `created_at`, which is fixed here (Active
    # Record keeps a timestamp that is already set) so the decision is made
    # from exactly the value that is stored and that verification re-reads.
    def compute_checksum
      self.created_at ||= Time.current if has_attribute?(:created_at)
      previous = self.class.chain_tip_checksum
      self.previous_checksum = previous if self.class.chain_parent_column?
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
        StandardAudit.report_error(e, { StandardAudit.config.audit_error_context_key => event_type })
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
