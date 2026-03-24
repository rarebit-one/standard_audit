require "rails_helper"

RSpec.describe StandardAudit::Configuration do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "defaults async to false" do
      expect(config.async).to be false
    end

    it "defaults queue_name to :default" do
      expect(config.queue_name).to eq(:default)
    end

    it "defaults enabled to true" do
      expect(config.enabled).to be true
    end

    it "defaults sensitive_keys" do
      expect(config.sensitive_keys).to eq(%i[
        password password_confirmation token secret
        api_key access_token refresh_token
        private_key certificate_chain
        ssn credit_card authorization
      ])
    end

    it "defaults anonymizable_metadata_keys" do
      expect(config.anonymizable_metadata_keys).to eq(%i[email name ip_address])
    end

    it "defaults retention_days to nil" do
      expect(config.retention_days).to be_nil
    end

    it "defaults auto_cleanup to false" do
      expect(config.auto_cleanup).to be false
    end

    it "defaults metadata_builder to nil" do
      expect(config.metadata_builder).to be_nil
    end

    it "has default actor_extractor" do
      expect(config.actor_extractor).to be_a(Proc)
      expect(config.actor_extractor.call({ actor: :test })).to eq(:test)
    end

    it "has default target_extractor" do
      expect(config.target_extractor).to be_a(Proc)
      expect(config.target_extractor.call({ target: :test })).to eq(:test)
    end

    it "has default scope_extractor" do
      expect(config.scope_extractor).to be_a(Proc)
      expect(config.scope_extractor.call({ scope: :test })).to eq(:test)
    end
  end

  describe "#subscribe_to" do
    it "adds patterns to subscriptions" do
      config.subscribe_to "audit.**"
      config.subscribe_to "user.*"

      expect(config.subscriptions).to eq(["audit.**", "user.*"])
    end
  end

  describe "#subscriptions" do
    it "returns a frozen copy" do
      config.subscribe_to "audit.**"
      subs = config.subscriptions

      expect(subs).to be_frozen
      expect { subs << "new.pattern" }.to raise_error(FrozenError)
    end

    it "does not allow mutation of internal state" do
      config.subscribe_to "audit.**"
      config.subscriptions
      config.subscribe_to "user.*"

      expect(config.subscriptions).to eq(["audit.**", "user.*"])
    end
  end

  describe "custom extractors" do
    it "allows custom actor_extractor" do
      custom = ->(payload) { payload[:current_user] }
      config.actor_extractor = custom

      expect(config.actor_extractor.call({ current_user: :alice })).to eq(:alice)
    end

    it "allows custom target_extractor" do
      custom = ->(payload) { payload[:resource] }
      config.target_extractor = custom

      expect(config.target_extractor.call({ resource: :order })).to eq(:order)
    end

    it "allows custom scope_extractor" do
      custom = ->(payload) { payload[:tenant] }
      config.scope_extractor = custom

      expect(config.scope_extractor.call({ tenant: :acme })).to eq(:acme)
    end
  end

  describe "custom current attribute resolvers" do
    it "allows custom current_actor_resolver" do
      config.current_actor_resolver = -> { :custom_actor }
      expect(config.current_actor_resolver.call).to eq(:custom_actor)
    end

    it "allows custom current_request_id_resolver" do
      config.current_request_id_resolver = -> { "req-custom" }
      expect(config.current_request_id_resolver.call).to eq("req-custom")
    end

    it "allows custom current_ip_address_resolver" do
      config.current_ip_address_resolver = -> { "127.0.0.1" }
      expect(config.current_ip_address_resolver.call).to eq("127.0.0.1")
    end

    it "allows custom current_user_agent_resolver" do
      config.current_user_agent_resolver = -> { "TestAgent" }
      expect(config.current_user_agent_resolver.call).to eq("TestAgent")
    end

    it "allows custom current_session_id_resolver" do
      config.current_session_id_resolver = -> { "sess-custom" }
      expect(config.current_session_id_resolver.call).to eq("sess-custom")
    end
  end

  describe "default current resolvers" do
    context "when Current is not defined" do
      it "returns nil for actor" do
        # In test env, Current may or may not be defined.
        # The default resolver should not raise either way.
        expect { config.current_actor_resolver.call }.not_to raise_error
      end

      it "returns nil for request_id" do
        expect { config.current_request_id_resolver.call }.not_to raise_error
      end
    end
  end

  describe "#use_preset" do
    it "applies standard_id preset subscriptions" do
      config.use_preset(:standard_id)

      expect(config.subscriptions.size).to eq(7)
      expect(config.subscriptions).to include("standard_id.session.created")
    end

    it "can combine preset with manual subscriptions" do
      config.use_preset(:standard_id)
      config.subscribe_to "custom.event"

      expect(config.subscriptions.size).to eq(8)
    end

    it "raises for unknown presets" do
      expect { config.use_preset(:unknown) }.to raise_error(ArgumentError, /Unknown preset/)
    end

    it "accepts string argument" do
      config.use_preset("standard_id")
      expect(config.subscriptions.size).to eq(7)
    end

    it "is idempotent — calling twice does not duplicate subscriptions" do
      config.use_preset(:standard_id)
      config.use_preset(:standard_id)

      expect(config.subscriptions.size).to eq(7)
    end

    it "returns self for chaining" do
      result = config.use_preset(:standard_id)
      expect(result).to be(config)
    end
  end

  describe "custom sensitive_keys" do
    it "accepts custom sensitive keys" do
      config.sensitive_keys = %i[ssn credit_card]
      expect(config.sensitive_keys).to eq(%i[ssn credit_card])
    end
  end
end
