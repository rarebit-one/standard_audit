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
    def call(metadata)
      return nil if metadata.nil?

      unless metadata.respond_to?(:each_pair) && metadata.respond_to?(:reject)
        raise UnfilterableMetadataError,
          "audit metadata must be nil or hash-like (got #{metadata.class}); " \
          "refusing to write it unfiltered"
      end

      metadata.reject { |key, _| filter?(key) }
    end

    # True when `key` would be redacted from metadata. Public so hosts (and the
    # dry-run tooling) can ask the question without writing a row.
    def filter?(key)
      key = key.to_s

      # `_tags` and `_source` are owned by EventSubscriber and are never
      # stripped, even if a consumer lists them in `sensitive_keys`.
      return false if StandardAudit::RESERVED_METADATA_KEYS.include?(key)

      sensitive_keys.include?(key)
    end

    private

    def sensitive_keys
      @sensitive_keys ||= @config.sensitive_keys.map(&:to_s) - StandardAudit::RESERVED_METADATA_KEYS
    end
  end
end
