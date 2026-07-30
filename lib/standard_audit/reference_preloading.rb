require "cgi"
require "active_support/concern"

module StandardAudit
  # Batch resolution of the GlobalID-backed `actor` / `target` / `scope`
  # references on a page of audit rows, plus the per-row memo the readers
  # consult.
  #
  # Why this exists: `AuditLog#actor` resolves `actor_gid` through
  # `GlobalID::Locator.locate`, which is one query per row. Rendering N rows
  # that each read `actor` and `target` issues O(N) lookups — an N+1 that
  # Prosopite fails in every consuming app. Before this concern existed, apps
  # worked around it by defining their own `preloaded_actor=` writer (or
  # reaching into `@preloaded_actor` with `instance_variable_set`) and
  # hand-rolling a per-type whitelist loader.
  #
  # == Memo semantics
  #
  # The memo is a Hash consulted with `key?`, not a pair of ivars checked with
  # `defined?`. That distinction matters: a reference that was preloaded but
  # whose record has since been deleted memoizes `nil`, and reads back as
  # `nil` *without* falling through to a query. "Preloaded, and the answer is
  # nothing" is therefore distinct from "not preloaded".
  #
  # `actor=` / `target=` / `scope=` populate the memo too, since the writer
  # already holds the record. `reload` clears it.
  #
  # == Batched writes
  #
  # `StandardAudit.batch { ... }` flushes through `insert_all!` and never
  # instantiates an AuditLog, so nothing in this concern runs on that path —
  # neither the memo nor the writers. It is a no-op for batched writes by
  # construction, not by accident.
  module ReferencePreloading
    extend ActiveSupport::Concern

    # The GlobalID-backed reference columns. `scope` is preloadable but not in
    # the default `refs:` set, since most read surfaces render actor/target
    # only.
    REFERENCES = %i[actor target scope].freeze

    DEFAULT_REFS = %i[actor target].freeze

    class_methods do
      # Resolves the given references for a whole collection of audit logs in a
      # fixed number of queries (one per distinct stored `*_type`), then
      # memoizes the result on each row.
      #
      #   AuditLog.preload_references(
      #     logs,
      #     refs: %i[actor target],
      #     only: [Account, Profile, Order],
      #     includes: { "Profile" => [:account], "Order" => [:user] }
      #   )
      #
      # [refs:]     Which references to resolve. Defaults to `%i[actor target]`.
      # [only:]     Optional whitelist of permitted classes. See the note below —
      #             this is matched against the *stored type string*, so it is
      #             a stricter gate than `GlobalID::Locator`'s own `:only`.
      # [includes:] Either a uniform Active Record `includes` spec applied to
      #             every type, or a per-type Hash keyed by class name String
      #             or Class constant (e.g. `{ "Profile" => [:account] }`).
      #             A Hash counts as per-type only when *every* key is a String
      #             or a Module; `{ account: :identifiers }` is therefore read
      #             as a uniform nested-includes spec, as you would expect.
      #
      # == Why `only:` is matched on the stored string
      #
      # `GlobalID::Locator`'s `:only` option is evaluated as
      # `gid.model_class <= klass`, which means it *constantizes the stored
      # type string before deciding whether it was allowed*. That is the wrong
      # order for audit rows, whose type strings are historical: a class that
      # has since been renamed or removed raises `NameError` rather than being
      # filtered out. So this method filters on the stored `*_type` string
      # first, by class name, and only then hands the surviving gids to
      # `locate_many` (still passing `only:` as a second gate).
      #
      # The consequence is that `only:` does **not** expand to subclasses or
      # to modules the way GlobalID's does — list every concrete class whose
      # name you expect to see in `actor_type` / `target_type`. Deny-by-default
      # is the safe direction for a whitelist.
      #
      # A reference whose type is not in `only:` memoizes `nil`, so it reads
      # back as nil without a query rather than silently re-N+1ing.
      #
      # Returns the logs as an Array.
      def preload_references(logs, refs: DEFAULT_REFS, only: nil, includes: nil)
        logs = logs.to_a
        return logs if logs.empty?

        Array(refs).each do |ref|
          ref = ref.to_sym
          unless REFERENCES.include?(ref)
            raise ArgumentError, "unknown audit reference #{ref.inspect} (expected one of #{REFERENCES.inspect})"
          end

          preload_one_reference(logs, ref, only: only, includes: includes)
        end

        logs
      end

      # Extracts the model id from a GlobalID string without resolving it:
      # "gid://some-app/Account/123" => "123".
      #
      # Deliberately *not* `GlobalID.parse(gid)&.model_id`. Audit gids are
      # historical and the rows are append-only, so a gid written by another
      # app — or before this app was renamed — is a real, permanent row whose
      # id must still be readable. Parsing it back through the locator
      # machinery resolves against the *current* `GlobalID.app`, which is not
      # what these rows are keyed on.
      #
      # This mirrors `URI::GID#set_model_components` exactly, minus the app
      # check and the validations: drop any `?params` query, take everything
      # after the model-name segment, split composite ids on "/", and
      # `CGI.unescape` each part (`URI::GID.build` `CGI.escape`s them). Returns
      # a String for a single-column primary key and an Array of Strings for a
      # composite one, matching `GlobalID#model_id`.
      def reference_model_id(gid)
        return nil if gid.blank?

        # "gid:" , "" , app , ModelName , <id segment(s)>
        segment = gid.to_s.split("?", 2).first.to_s.split("/", 5)[4]
        return nil if segment.blank?

        parts = segment.split("/").reject(&:blank?).map { |part| CGI.unescape(part) }
        return nil if parts.empty?

        parts.length == 1 ? parts.first : parts
      end

      private

      def preload_one_reference(logs, ref, only:, includes:)
        gid_attr = :"#{ref}_gid"
        type_attr = :"#{ref}_type"
        allowed_names = only && Array(only).map { |klass| klass.is_a?(Module) ? klass.name : klass.to_s }

        index = {}
        unresolvable_types = []

        logs.group_by { |log| log.public_send(type_attr) }.each do |type, type_logs|
          # A blank `*_type` with a populated `*_gid` happens on historical and
          # partially-backfilled rows. The per-row reader can still resolve
          # those (the gid carries the model name), so mark the group
          # unresolvable rather than memoizing nil — batching must never make a
          # resolvable reference read back as nothing.
          if type.blank?
            unresolvable_types << type
            next
          end

          # Not whitelisted: intentionally left out of the index so it memoizes
          # nil (no query, now or later).
          next if allowed_names && !allowed_names.include?(type)

          gids = type_logs.filter_map { |log| log.public_send(gid_attr).presence }.uniq
          next if gids.empty?

          begin
            locate_reference_records(gids, only: only, includes: includes_for(includes, type)).each do |record|
              index[[type, normalized_record_key(record.id)]] = record
            end
          rescue NameError, ActiveRecord::StatementInvalid => e
            # A historical type string that no longer constantizes, or a
            # relation the current schema can't satisfy. Leave these rows
            # *unmemoized* so the per-row reader behaves exactly as it did
            # before preloading was attempted — memoizing nil here would
            # silently rewrite behaviour on a bad `includes:`.
            unresolvable_types << type
            Rails.logger.warn("[StandardAudit] Could not preload #{ref} for type #{type.inspect}: #{e.class}: #{e.message}")
          end
        end

        logs.each do |log|
          type = log.public_send(type_attr)
          next if unresolvable_types.include?(type)

          log.write_preloaded_reference(
            ref,
            index[[type, reference_model_id(log.public_send(gid_attr))]]
          )
        end
      end

      # `ignore_missing: true` makes this a `where(id: ids)` instead of
      # `find(ids)`, so a deleted record is simply absent from the result
      # rather than raising — which is what lets a deleted reference memoize
      # nil.
      def locate_reference_records(gids, only:, includes:)
        options = { ignore_missing: true }
        options[:only] = only if only
        options[:includes] = includes if includes

        GlobalID::Locator.locate_many(gids, options)
      end

      # Mirrors how `GlobalID::Locator::BaseLocator#locate_many` keys its own
      # result index, so composite primary keys line up with
      # `reference_model_id`.
      def normalized_record_key(id)
        id.is_a?(Array) ? id.map(&:to_s) : id.to_s
      end

      def includes_for(includes, type)
        return nil if includes.nil?
        return includes unless per_type_includes?(includes)

        entry = includes.find { |key, _| (key.is_a?(Module) ? key.name : key.to_s) == type }
        entry&.last
      end

      # A Hash counts as a per-type mapping only when every key names a class.
      # Symbol keys mean the caller passed an Active Record includes spec such
      # as `{ account: :identifiers }`, which must be applied uniformly.
      def per_type_includes?(includes)
        includes.is_a?(Hash) &&
          includes.any? &&
          includes.keys.all? { |key| key.is_a?(String) || key.is_a?(Module) }
      end
    end

    # Writers. `preloaded_actor = record_or_nil` is the supported way to hand a
    # separately-resolved record to a log; `nil` means "resolved to nothing",
    # not "clear the memo".
    REFERENCES.each do |ref|
      define_method(:"preloaded_#{ref}=") do |record|
        write_preloaded_reference(ref, record)
      end

      define_method(:"#{ref}_preloaded?") do
        reference_preloaded?(ref)
      end

      # `actor_model_id` / `target_model_id` / `scope_model_id` — the trailing
      # gid segment, without needing the record.
      define_method(:"#{ref}_model_id") do
        self.class.reference_model_id(public_send(:"#{ref}_gid"))
      end
    end

    # The memo itself. Public because `preload_references` writes through it
    # from the class side; treat it as gem-internal — `preloaded_actor=` and
    # `actor_preloaded?` are the supported surface.
    def preloaded_references
      @preloaded_references ||= {}
    end

    def reference_preloaded?(ref)
      preloaded_references.key?(ref.to_sym)
    end

    # See `preloaded_references` — gem-internal, but public so the class-level
    # preloader can reach it.
    def write_preloaded_reference(ref, record)
      preloaded_references[ref.to_sym] = record
    end

    # Drops the memo so the next read re-resolves from the (possibly changed)
    # gid columns.
    def reload(...)
      @preloaded_references = nil
      super
    end

    private

    # The single-row fallback: identical to the pre-0.7.0 reader behaviour.
    def locate_reference(ref)
      gid = public_send(:"#{ref}_gid")
      return nil if gid.blank?

      GlobalID::Locator.locate(gid)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def read_reference(ref)
      ref = ref.to_sym
      return preloaded_references[ref] if preloaded_references.key?(ref)

      locate_reference(ref)
    end

    def assign_reference(ref, record)
      if record.nil?
        public_send(:"#{ref}_gid=", nil)
        public_send(:"#{ref}_type=", nil)
      else
        public_send(:"#{ref}_gid=", record.to_global_id.to_s)
        public_send(:"#{ref}_type=", record.class.name)
      end

      write_preloaded_reference(ref, record)
      record
    end
  end
end
