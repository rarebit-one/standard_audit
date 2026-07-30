module StandardAudit
  # The single implementation of sensitive-key redaction for audit metadata.
  #
  # There used to be two: one in `StandardAudit.record` and one in
  # `Subscriber#extract_metadata`. They had already diverged — the subscriber
  # copy did not subtract `RESERVED_METADATA_KEYS`, so an app that (reasonably)
  # added `:_tags` to `sensitive_keys` got the reserved key preserved on the
  # `record` path and stripped on the `ActiveSupport::Notifications` path. Two
  # copies of a security filter drifting apart is exactly the failure mode
  # worth designing out, so both paths now call here.
  #
  # The divergence is resolved in favour of `record`'s behaviour: reserved keys
  # are subtracted from the sensitive set and can never be filtered.
  #
  # == Matching
  #
  # A key is redacted when it matches `config.sensitive_keys` **exactly** (by
  # name, string/symbol insensitive) or matches one of
  # `config.sensitive_key_patterns` (Regexps, always applied), unless it is
  # listed in `config.sensitive_key_exceptions` or is a reserved key.
  #
  # == Why there is no substring mode
  #
  # Matching `sensitive_keys` by substring instead of exactly is the obvious
  # "fix" for `client_secret` not matching `:secret`, and it is a trap. Against
  # the current default key list it would strip real audit content across the
  # estate:
  #
  #   :token   => input_tokens, output_tokens (live LLM cost accounting),
  #              token_digest (rendered in a staff audit UI)
  #   :password => password_reset_sent_at, onepassword
  #   :authorization => authorization_endpoint
  #
  # Audit rows are append-only, so a bad default cannot be undone — the content
  # is simply never written. `sensitive_key_patterns` is the supported tool
  # instead: `/secret/i` solves the motivating `client_secret` case exactly,
  # opt-in and per-app, and `rake standard_audit:sensitive_keys:dry_run` turns
  # "is this rule safe for my data?" into a command rather than a guess.
  class MetadataFilter
    # Raised when metadata is neither nil nor hash-like. Deliberately a raise
    # rather than a pass-through: this filter **fails closed**. An
    # `ActionController::Parameters` is not a `Hash`, and letting an unrecognised
    # object through unfiltered would write raw params — passwords included —
    # into an append-only row. Pre-0.7.0 the same input blew up with
    # `NoMethodError` on `#reject`, so raising preserves the outcome while
    # naming the cause.
    class UnfilterableMetadataError < ArgumentError; end

    class << self
      def call(metadata, config: StandardAudit.config)
        new(config: config).call(metadata)
      end
    end

    def initialize(config: StandardAudit.config)
      @config = config
    end

    # Filters anything hash-like, not just `Hash` — `ActionController::Parameters`
    # and other `each_pair`-able wrappers are filtered rather than waved
    # through. `nil` passes (there is nothing to leak); anything else raises.
    #
    # Descends into nested Hashes (and Hashes inside Arrays) only when
    # `config.filter_nested_metadata` is true. Reserved keys are preserved and
    # their values are left entirely alone, **at every depth** — `_tags` and
    # `_source` are gem-owned, not host payload, and immunity that held only at
    # the top level would be a confusing half-guarantee.
    def call(metadata)
      return nil if metadata.nil?

      unless hash_like?(metadata)
        raise UnfilterableMetadataError,
          "audit metadata must be nil or hash-like (got #{metadata.class}); " \
          "refusing to write it unfiltered"
      end

      filtered = metadata.reject { |key, _| filter?(key) }
      return filtered unless @config.filter_nested_metadata

      filter_values(filtered)
    end

    # True when `key` would be redacted from metadata. Public so hosts (and the
    # dry-run tooling) can ask the question without writing a row.
    def filter?(key)
      key = key.to_s

      # `_tags` and `_source` are owned by EventSubscriber and are never
      # stripped, even if a consumer lists them in `sensitive_keys`.
      return false if StandardAudit::RESERVED_METADATA_KEYS.include?(key)
      return false if exception?(key)

      sensitive_keys.include?(key) || sensitive_key_patterns.any? { |pattern| pattern.match?(key) }
    end

    private

    def hash_like?(value)
      value.respond_to?(:each_pair) && value.respond_to?(:reject)
    end

    # Rewrites each value in place on the already-rejected copy. In place
    # because `transform_values` is not guaranteed across every hash-like
    # wrapper, whereas `[]=` is.
    def filter_values(hash)
      hash.each_pair do |key, value|
        # Reserved subtree: immune at every depth, never descended into.
        next if StandardAudit::RESERVED_METADATA_KEYS.include?(key.to_s)

        replacement = filter_descendant(value)
        hash[key] = replacement unless replacement.equal?(value)
      end

      hash
    end

    def filter_descendant(value)
      if hash_like?(value)
        filter_values(value.reject { |key, _| filter?(key) })
      elsif value.is_a?(Array)
        value.map { |element| filter_descendant(element) }
      else
        value
      end
    end

    def sensitive_keys
      @sensitive_keys ||= @config.sensitive_keys.map(&:to_s) - StandardAudit::RESERVED_METADATA_KEYS
    end

    # A String entry is read as a Regexp source, so the rake task (and a
    # `SENSITIVE_KEY_PATTERNS` env var) can pass one through without eval.
    def sensitive_key_patterns
      @sensitive_key_patterns ||= Array(@config.sensitive_key_patterns).map do |pattern|
        pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern.to_s)
      end
    end

    def exception?(key)
      exact_exceptions.include?(key) || pattern_exceptions.any? { |pattern| pattern.match?(key) }
    end

    def exceptions
      @exceptions ||= Array(@config.sensitive_key_exceptions).partition { |entry| entry.is_a?(Regexp) }
    end

    def pattern_exceptions
      exceptions.first
    end

    def exact_exceptions
      @exact_exceptions ||= exceptions.last.map(&:to_s)
    end
  end
end
