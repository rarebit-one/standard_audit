require "rails_helper"

# rarebit-one/rarebit-ops#296: `standard_id` publishes ActiveRecord objects
# under payload keys like `account:`, `session:` and `code_challenge:`, and an
# AR object serialises with every attribute it has. `password_digest`,
# `token_digest`, `lookup_hash` and PKCE verifiers therefore landed in
# append-only `audit_logs` rows.
#
# These specs assert the digest column names are ABSENT from what is written,
# not merely that the metadata shape changed.
RSpec.describe StandardAudit::RecordReference do
  let(:user) do
    User.create!(
      name: "Alice",
      email: "alice@example.com",
      password_digest: "$2a$12$super-secret-digest",
      token_digest: "e3b0c44298fc1c149afbf4c8996fb924"
    )
  end

  def json_of(value)
    value.to_json
  end

  describe ".call" do
    it "replaces a record with a gid/type/id reference" do
      result = described_class.call({ account: user })

      expect(result[:account]).to eq(
        "gid" => user.to_global_id.to_s,
        "type" => "User",
        "id" => user.id.to_s
      )
    end

    it "writes no record attributes at all" do
      serialised = json_of(described_class.call({ account: user }))

      expect(serialised).not_to include("password_digest")
      expect(serialised).not_to include("token_digest")
      expect(serialised).not_to include("super-secret-digest")
      expect(serialised).not_to include("alice@example.com")
    end

    it "omits the gid for an unpersisted record but still identifies it" do
      result = described_class.call({ account: User.new(name: "Bob", password_digest: "nope") })

      expect(result[:account]).to eq("type" => "User")
      expect(json_of(result)).not_to include("password_digest")
    end

    it "dereferences records nested inside hashes" do
      result = described_class.call({ context: { inner: { account: user } } })

      expect(result[:context][:inner][:account]["gid"]).to eq(user.to_global_id.to_s)
      expect(json_of(result)).not_to include("password_digest")
    end

    it "dereferences records inside arrays" do
      other = User.create!(name: "Bob", email: "bob@example.com", token_digest: "deadbeef")

      result = described_class.call({ accounts: [user, other] })

      expect(result[:accounts].map { |ref| ref["id"] }).to eq([user.id.to_s, other.id.to_s])
      expect(json_of(result)).not_to include("token_digest")
      expect(json_of(result)).not_to include("deadbeef")
    end

    it "dereferences an ActiveRecord::Relation" do
      user

      result = described_class.call({ accounts: User.where(id: user.id) })

      expect(result[:accounts]).to eq([described_class.reference_for(user)])
    end

    it "leaves plain metadata untouched, and untouched means the same object" do
      metadata = { reason: "manual", counts: { input_tokens: 12, output_tokens: 34 }, tags: ["a", "b"] }

      result = described_class.call(metadata)

      expect(result).to equal(metadata)
      expect(result).to eq(reason: "manual", counts: { input_tokens: 12, output_tokens: 34 }, tags: ["a", "b"])
    end

    it "does not mutate the payload it was handed" do
      inner = { account: user }
      metadata = { context: inner }

      described_class.call(metadata)

      expect(inner[:account]).to equal(user)
    end

    it "leaves reserved keys entirely alone" do
      result = described_class.call({ "_tags" => ["auth"], "_source" => "engine", account: user })

      expect(result["_tags"]).to eq(["auth"])
      expect(result["_source"]).to eq("engine")
    end

    it "marks a circular reference rather than recursing forever" do
      cyclic = {}
      cyclic[:self] = cyclic

      expect { described_class.call(cyclic) }.not_to raise_error
      expect(described_class.call(cyclic)).to eq(self: described_class::CIRCULAR)
    end

    it "handles a cycle through an Array" do
      cyclic = []
      cyclic << cyclic

      expect(described_class.call({ items: cyclic })).to eq(items: [described_class::CIRCULAR])
    end

    it "keeps deeply but finitely nested record-free metadata intact" do
      deep = (1..30).reduce("leaf") { |inner, i| { "level_#{i}": inner } }

      result = described_class.call(deep)

      expect(result).to equal(deep)
      expect(json_of(result)).to include("leaf")
    end

    it "dereferences a record buried far below any plausible depth cap" do
      deep = (1..30).reduce({ account: user }) { |inner, i| { "level_#{i}": inner } }

      serialised = json_of(described_class.call(deep))

      expect(serialised).to include(user.to_global_id.to_s)
      expect(serialised).not_to include("password_digest")
    end

    it "does not mistake a repeated (but non-circular) sibling for a cycle" do
      shared = { account: user }

      result = described_class.call({ a: shared, b: shared })

      expect(result[:a]).to eq(result[:b])
      expect(result[:a][:account]["type"]).to eq("User")
    end
  end

  describe "the Subscriber write path" do
    let(:subscriber) { StandardAudit::Subscriber.new }

    before do
      StandardAudit.instance_variable_set(:@configuration, nil)
      StandardAudit.instance_variable_set(:@subscriber, nil)
      StandardAudit.configure { |config| config.subscribe_to "audit.test" }
      subscriber.setup!
    end

    after do
      subscriber.teardown!
      StandardAudit.instance_variable_set(:@configuration, nil)
      StandardAudit.instance_variable_set(:@subscriber, nil)
    end

    it "writes a reference, not the account's attributes" do
      ActiveSupport::Notifications.instrument("audit.test", { account: user, session: user })

      log = StandardAudit::AuditLog.last
      expect(log.metadata["account"]).to eq(
        "gid" => user.to_global_id.to_s, "type" => "User", "id" => user.id.to_s
      )
      expect(log.metadata.to_json).not_to include("password_digest")
      expect(log.metadata.to_json).not_to include("token_digest")
    end

    it "still hands the record to metadata_builder, which runs first" do
      StandardAudit.config.metadata_builder = ->(metadata) {
        metadata.merge(account_email: metadata[:account]&.email)
      }

      ActiveSupport::Notifications.instrument("audit.test", { account: user })

      log = StandardAudit::AuditLog.last
      expect(log.metadata["account_email"]).to eq("alice@example.com")
      expect(log.metadata.to_json).not_to include("password_digest")
    end

    it "can be opted out of, at which point the attributes come back" do
      StandardAudit.config.dereference_record_metadata = false

      ActiveSupport::Notifications.instrument("audit.test", { account: user })

      expect(StandardAudit::AuditLog.last.metadata.to_json).to include("password_digest")
    end
  end

  describe "the StandardAudit.record write path" do
    before { StandardAudit.instance_variable_set(:@configuration, nil) }

    after { StandardAudit.instance_variable_set(:@configuration, nil) }

    it "writes a reference, not the record's attributes" do
      log = StandardAudit.record("audit.direct", metadata: { account: user }).reload

      expect(log.metadata["account"]).to eq(
        "gid" => user.to_global_id.to_s, "type" => "User", "id" => user.id.to_s
      )
      expect(log.metadata.to_json).not_to include("password_digest")
    end

    it "does no dereferencing in the block form, where the Subscriber writes the row" do
      expect(StandardAudit::RecordReference).not_to receive(:call)

      StandardAudit.record("audit.direct", metadata: { accounts: User.where(id: user.id) }) { :done }
    end
  end
end
