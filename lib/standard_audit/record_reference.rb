module StandardAudit
  # Replaces ActiveRecord objects found in audit metadata with a stable
  # *reference* instead of a snapshot of the record's whole attribute set.
  #
  # == Why this exists
  #
  # `ActiveSupport::Notifications` payloads routinely carry live records —
  # `standard_id` publishes `account:`, `current_account:`, `session:` and
  # `code_challenge:` — and an AR object serialises with every attribute it
  # has. That put `account.password_digest`,
  # `account.password_reset_token_digest`, `session.token_digest`,
  # `session.lookup_hash` and `code_challenge.code` into `audit_logs` rows
  # across the estate (rarebit-one/rarebit-ops#296).
  #
  # None of the three existing defences fired: `sensitive_keys` matches keys
  # exactly and the secrets are attributes *underneath* `account:`;
  # `filter_nested_metadata` is off by default so the filter never descended
  # to them; and `account:` does not look sensitive at the top level.
  #
  # Key-based redaction is the wrong tool here — the leak is not "this key is
  # sensitive", it is "this value is an entire database row". So the value is
  # replaced wholesale, by type, before any key filtering happens.
  #
  # == What replaces a record
  #
  #   { "gid" => "gid://dummy/Account/1", "type" => "Account", "id" => "1" }
  #
  # A GlobalID string is the identifier this gem already uses for `actor`,
  # `target` and `scope` (`actor_gid`), so an audit row stays resolvable with
  # `GlobalID::Locator`. `type` and `id` ride along because they survive a
  # record being deleted, an app whose GlobalID app name changes, and records
  # that have no GlobalID at all (unpersisted ones): for those, `gid` is
  # simply absent and the reference is still meaningful.
  module RecordReference
    # Written in place of a container that contains itself. Depth alone is NOT
    # used as the guard: a plain depth cap would rewrite deeply-but-finitely
    # nested metadata that holds no records at all, and permanently lose audit
    # content in an append-only row to protect against a structure that is
    # merely large. Only a genuine cycle — the one thing that cannot be
    # serialised anyway — is replaced.
    CIRCULAR = "[standard_audit: circular reference]".freeze

    class << self
      # Returns a copy of `value` with every ActiveRecord object — at any
      # depth, inside Arrays, Hashes and Relations — replaced by a reference
      # Hash. Structures containing no records are returned untouched (same
      # object), so this is a no-op for ordinary metadata.
      #
      # Never mutates the input: notification payloads are shared with every
      # other subscriber.
      def call(value, ancestors = nil)
        return reference_for(value) if record?(value)

        container = relation?(value) || value.is_a?(Array) || hash_like?(value)
        return value unless container

        ancestors ||= {}.compare_by_identity
        return CIRCULAR if ancestors.key?(value)

        ancestors[value] = true
        begin
          if relation?(value)
            map_collection(value.to_a, ancestors)
          elsif value.is_a?(Array)
            map_collection(value, ancestors)
          else
            map_hash(value, ancestors)
          end
        ensure
          ancestors.delete(value)
        end
      end

      # The reference written in place of a record.
      def reference_for(record)
        {
          "gid" => global_id_for(record),
          "type" => record.class.name,
          "id" => record.id&.to_s
        }.compact
      end

      private

      def record?(value)
        defined?(ActiveRecord::Base) && value.is_a?(ActiveRecord::Base)
      end

      def relation?(value)
        defined?(ActiveRecord::Relation) && value.is_a?(ActiveRecord::Relation)
      end

      def hash_like?(value)
        value.respond_to?(:each_pair) && value.respond_to?(:key?)
      end

      def map_collection(array, ancestors)
        changed = false
        mapped = array.map do |element|
          replacement = call(element, ancestors)
          changed ||= !replacement.equal?(element)
          replacement
        end

        changed ? mapped : array
      end

      def map_hash(hash, ancestors)
        changed = false
        mapped = {}

        hash.each_pair do |key, value|
          # Reserved keys are gem-owned (`_tags`, `_source`) and are left
          # exactly alone here, as they are in MetadataFilter.
          if StandardAudit::RESERVED_METADATA_KEYS.include?(key.to_s)
            mapped[key] = value
            next
          end

          replacement = call(value, ancestors)
          changed ||= !replacement.equal?(value)
          mapped[key] = replacement
        end

        changed ? mapped : hash
      end

      # `to_global_id` raises for an unpersisted record and for a model that
      # does not include GlobalID::Identification. Neither is a reason to fail
      # an audit write, and neither is a reason to fall back to writing the
      # attributes.
      def global_id_for(record)
        return nil unless record.respond_to?(:to_global_id)

        record.to_global_id.to_s
      rescue StandardError
        nil
      end
    end
  end
end
