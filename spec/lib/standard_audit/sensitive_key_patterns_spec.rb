require "rails_helper"

# `sensitive_key_patterns`, `sensitive_key_exceptions` and
# `filter_nested_metadata` all live in MetadataFilter, so both write paths get
# them for free. The parity shared example covers the paths; this file covers
# the semantics.
RSpec.describe "sensitive key patterns and nested filtering" do
  before { StandardAudit.reset_configuration! }
  after { StandardAudit.reset_configuration! }

  def filtered(metadata)
    StandardAudit::MetadataFilter.call(metadata)
  end

  describe "defaults (0.6.0 behaviour preserved)" do
    it "applies no patterns, no exceptions, and no nested filtering" do
      expect(StandardAudit.config.sensitive_key_patterns).to eq([])
      expect(StandardAudit.config.sensitive_key_exceptions).to eq([])
      expect(StandardAudit.config.filter_nested_metadata).to be(false)
    end

    it "leaves nested metadata alone" do
      metadata = { stripe: { client_secret: "sk_live_x" } }

      expect(filtered(metadata)).to eq(stripe: { client_secret: "sk_live_x" })
    end

    it "does not strip keys that merely contain a default sensitive key" do
      metadata = {
        input_tokens: 10, output_tokens: 20, token_digest: "abc",
        password_reset_sent_at: "t", authorization_endpoint: "https://x",
        onepassword: "vault"
      }

      expect(filtered(metadata).keys).to match_array(metadata.keys)
    end
  end

  describe "config.sensitive_key_patterns" do
    it "solves the motivating client_secret case with /secret/i" do
      StandardAudit.config.sensitive_key_patterns = [/secret/i]

      metadata = { client_secret: "sk_live_x", webhook_secret: "whsec", Secret: "s", order_id: 1 }

      expect(filtered(metadata).keys).to eq([:order_id])
    end

    it "is applied in addition to sensitive_keys, not instead of" do
      StandardAudit.config.sensitive_key_patterns = [/\Astripe_/]

      expect(filtered({ password: "x", stripe_id: "y", kept: "z" }).keys).to eq([:kept])
    end

    it "accepts a String as a Regexp source" do
      StandardAudit.config.sensitive_key_patterns = ["secret"]

      expect(filtered({ client_secret: "x", kept: "y" }).keys).to eq([:kept])
    end

    it "never strips reserved keys, however broad the pattern" do
      StandardAudit.config.sensitive_key_patterns = [/./]

      metadata = { _tags: { a: 1 }, _source: "x.rb:1", anything: "gone" }

      expect(filtered(metadata).keys).to match_array(%i[_tags _source])
    end
  end

  describe "config.sensitive_key_exceptions" do
    it "rescues a real audit key from a broad pattern" do
      StandardAudit.config.sensitive_key_patterns = [/token/i]
      StandardAudit.config.sensitive_key_exceptions = %i[input_tokens output_tokens]

      metadata = { input_tokens: 10, output_tokens: 20, refresh_token: "rt", token_digest: "td" }

      expect(filtered(metadata).keys).to match_array(%i[input_tokens output_tokens])
    end

    it "also overrides the exact-match sensitive_keys list" do
      StandardAudit.config.sensitive_key_exceptions = %i[authorization]

      expect(filtered({ authorization: "policy-allow", password: "x" }).keys).to eq([:authorization])
    end

    it "accepts a Regexp exception" do
      StandardAudit.config.sensitive_key_patterns = [/token/i]
      StandardAudit.config.sensitive_key_exceptions = [/\A(input|output)_tokens\z/]

      expect(filtered({ input_tokens: 1, access_token: "x" }).keys).to eq([:input_tokens])
    end

    it "accepts String entries as exact names" do
      StandardAudit.config.sensitive_key_exceptions = ["password"]

      expect(filtered({ password: "x" }).keys).to eq([:password])
    end
  end

  describe "config.filter_nested_metadata" do
    before { StandardAudit.config.filter_nested_metadata = true }

    it "redacts a nested sensitive key" do
      # `client_secret` is not a default key — `:secret` is, and matching is
      # exact — so the app opts in with a pattern, exactly as nutripod does.
      StandardAudit.config.sensitive_key_patterns = [/secret/i]
      metadata = { stripe: { client_secret: "sk", id: "ch_1" } }

      expect(filtered(metadata)).to eq(stripe: { id: "ch_1" })
    end

    it "applies patterns at depth" do
      StandardAudit.config.sensitive_key_patterns = [/secret/i]
      metadata = { a: { b: { c: { webhook_secret: "x", kept: 1 } } } }

      expect(filtered(metadata)).to eq(a: { b: { c: { kept: 1 } } })
    end

    it "descends into Hashes inside Arrays" do
      metadata = { charges: [{ password: "x", id: 1 }, { id: 2 }] }

      expect(filtered(metadata)).to eq(charges: [{ id: 1 }, { id: 2 }])
    end

    it "leaves non-Hash values untouched" do
      metadata = { list: [1, "two", nil], count: 3 }

      expect(filtered(metadata)).to eq(list: [1, "two", nil], count: 3)
    end

    it "leaves the reserved _tags / _source subtrees entirely alone" do
      # Reserved keys are gem-owned. Descending into them would let a
      # host-configured rule rewrite EventSubscriber's own metadata.
      StandardAudit.config.sensitive_key_patterns = [/./]
      metadata = { _tags: { password: "kept-because-reserved-subtree" }, _source: "x.rb:1" }

      expect(filtered(metadata)).to eq(metadata)
    end

    it "keeps a reserved subtree immune at depth, not just at the top level" do
      # Immunity that held only at the top level would be a half-guarantee: a
      # host rule could rewrite _tags content one level down.
      metadata = { outer: { _tags: { password: "kept" }, password: "gone" } }

      expect(filtered(metadata)).to eq(outer: { _tags: { password: "kept" } })
    end

    it "does not mutate the caller's Hash" do
      StandardAudit.config.sensitive_key_patterns = [/secret/i]
      metadata = { stripe: { client_secret: "sk", id: "ch_1" } }
      filtered(metadata)

      expect(metadata).to eq(stripe: { client_secret: "sk", id: "ch_1" })
    end

    it "reaches rows written through StandardAudit.record" do
      StandardAudit.config.sensitive_key_patterns = [/secret/i]
      log = StandardAudit.record("audit.nested.test", metadata: { stripe: { client_secret: "sk", id: "ch_1" } })

      expect(log.metadata).to eq("stripe" => { "id" => "ch_1" })
    end

    it "reaches rows written through the AS::Notifications subscriber" do
      subscriber = nil
      subscriber = StandardAudit::Subscriber.new
      StandardAudit.config.sensitive_key_patterns = [/secret/i]
      StandardAudit.config.subscribe_to "audit.nested.subscriber"
      subscriber.setup!

      ActiveSupport::Notifications.instrument("audit.nested.subscriber", stripe: { client_secret: "sk", id: "ch_1" })

      expect(StandardAudit::AuditLog.last.metadata).to eq("stripe" => { "id" => "ch_1" })
    ensure
      subscriber&.teardown!
    end
  end
end
