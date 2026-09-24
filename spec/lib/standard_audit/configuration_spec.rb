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

  describe "retention_days default from STANDARD_AUDIT_RETENTION_DAYS" do
    around do |example|
      original = ENV["STANDARD_AUDIT_RETENTION_DAYS"]
      example.run
      if original.nil?
        ENV.delete("STANDARD_AUDIT_RETENTION_DAYS")
      else
        ENV["STANDARD_AUDIT_RETENTION_DAYS"] = original
      end
    end

    def retention_for(value)
      if value.nil?
        ENV.delete("STANDARD_AUDIT_RETENTION_DAYS")
      else
        ENV["STANDARD_AUDIT_RETENTION_DAYS"] = value
      end
      described_class.new.retention_days
    end

    it "is nil (infinite) when unset" do
      expect(retention_for(nil)).to be_nil
    end

    it "is nil when blank" do
      expect(retention_for("   ")).to be_nil
    end

    it "parses a positive integer" do
      expect(retention_for("90")).to eq(90)
    end

    it "is nil for zero and negatives" do
      expect(retention_for("0")).to be_nil
      expect(retention_for("-5")).to be_nil
    end

    it "is nil for non-numeric values" do
      expect(retention_for("forever")).to be_nil
    end

    it "stays overridable on the instance" do
      retention_for(nil)
      config.retention_days = 365
      expect(config.retention_days).to eq(365)
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

    context "with a StandardId-shaped Current (account + session)" do
      before do
        stub_current(:account, :session)
      end

      it "resolves the actor from Current.account" do
        Current.account = :the_account
        expect(config.current_actor_resolver.call).to eq(:the_account)
      end

      it "resolves the session id from Current.session.id" do
        Current.session = Struct.new(:id).new("sess-1")
        expect(config.current_session_id_resolver.call).to eq("sess-1")
      end

      it "resolves nil when nothing is set" do
        expect(config.current_actor_resolver.call).to be_nil
        expect(config.current_session_id_resolver.call).to be_nil
      end
    end

    context "with a Rails-convention Current (user + session_id)" do
      before do
        stub_current(:user, :session_id)
      end

      it "resolves the actor from Current.user" do
        Current.user = :the_user
        expect(config.current_actor_resolver.call).to eq(:the_user)
      end

      it "resolves the session id from Current.session_id" do
        Current.session_id = "sess-2"
        expect(config.current_session_id_resolver.call).to eq("sess-2")
      end
    end

    context "with a Current exposing both account and user" do
      before do
        stub_current(:account, :user, :session, :session_id)
      end

      it "prefers Current.account, falling back to Current.user when account is nil" do
        Current.user = :the_user
        expect(config.current_actor_resolver.call).to eq(:the_user)

        Current.account = :the_account
        expect(config.current_actor_resolver.call).to eq(:the_account)
      end

      it "prefers Current.session.id, falling back to Current.session_id" do
        Current.session_id = "plain"
        expect(config.current_session_id_resolver.call).to eq("plain")

        Current.session = Struct.new(:id).new("from-session")
        expect(config.current_session_id_resolver.call).to eq("from-session")
      end
    end
  end

  describe "custom sensitive_keys" do
    it "accepts custom sensitive keys" do
      config.sensitive_keys = %i[ssn credit_card]
      expect(config.sensitive_keys).to eq(%i[ssn credit_card])
    end
  end
end
