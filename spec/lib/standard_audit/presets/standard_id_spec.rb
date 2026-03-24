require "rails_helper"
require "standard_audit/presets/standard_id"

RSpec.describe StandardAudit::Presets::StandardId do
  describe "SUBSCRIPTIONS" do
    it "includes authentication, session, account, social, and passwordless patterns" do
      subs = described_class::SUBSCRIPTIONS

      expect(subs).to include(/\Astandard_id\.authentication\./)
      expect(subs).to include("standard_id.session.created")
      expect(subs).to include("standard_id.session.revoked")
      expect(subs).to include("standard_id.session.expired")
      expect(subs).to include(/\Astandard_id\.account\./)
      expect(subs).to include(/\Astandard_id\.social\./)
      expect(subs).to include(/\Astandard_id\.passwordless\./)
    end

    it "is frozen" do
      expect(described_class::SUBSCRIPTIONS).to be_frozen
    end
  end

  describe ".apply" do
    it "adds all subscriptions to the config" do
      config = StandardAudit::Configuration.new
      described_class.apply(config)

      expect(config.subscriptions.size).to eq(7)
      expect(config.subscriptions).to include("standard_id.session.created")
      expect(config.subscriptions).to include(a_kind_of(Regexp))
    end
  end
end
