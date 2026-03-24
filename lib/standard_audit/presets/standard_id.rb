module StandardAudit
  module Presets
    module StandardId
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
