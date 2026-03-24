module StandardAudit
  module Presets
    module StandardId
      # Regex wildcards capture all events in a namespace. Session uses
      # explicit strings to exclude noisy events like session.validated
      # that fire on every authenticated request.
      SUBSCRIPTIONS = [
        /\Astandard_id\.authentication\./,
        "standard_id.session.created",
        "standard_id.session.revoked",
        "standard_id.session.expired",
        /\Astandard_id\.account\./,
        /\Astandard_id\.social\./,
        /\Astandard_id\.passwordless\./
      ].freeze

      def self.apply(config)
        SUBSCRIPTIONS.each { |pattern| config.subscribe_to(pattern) }
      end
    end
  end
end
