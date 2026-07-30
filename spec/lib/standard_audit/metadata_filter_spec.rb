require "rails_helper"

RSpec.describe StandardAudit::MetadataFilter do
  before { StandardAudit.reset_configuration! }
  after { StandardAudit.reset_configuration! }

  describe ".call" do
    it "removes sensitive keys and keeps the rest" do
      expect(described_class.call({ password: "x", note: "keep" })).to eq(note: "keep")
    end

    it "preserves reserved keys even when they are listed as sensitive" do
      StandardAudit.config.sensitive_keys += %i[_tags]

      expect(described_class.call({ _tags: { a: 1 }, password: "x" })).to eq(_tags: { a: 1 })
    end

    it "passes nil through" do
      expect(described_class.call(nil)).to be_nil
    end

    it "filters hash-like input that is not a Hash, rather than waving it through" do
      # ActionController::Parameters is the real-world case: not a Hash, but
      # each_pair-able. Passing it through unfiltered would write raw params —
      # passwords included — into an append-only row.
      params = ActionController::Parameters.new(password: "hunter2", note: "keep")

      filtered = described_class.call(params)

      expect(filtered.keys).to eq(["note"])
    end

    it "fails closed on input it cannot filter" do
      expect { described_class.call("raw") }
        .to raise_error(StandardAudit::MetadataFilter::UnfilterableMetadataError, /hash-like/)
      expect { described_class.call(42) }
        .to raise_error(StandardAudit::MetadataFilter::UnfilterableMetadataError)
    end

    it "leaves the input Hash unmutated" do
      metadata = { password: "x", note: "keep" }
      described_class.call(metadata)

      expect(metadata).to eq(password: "x", note: "keep")
    end

    it "reads from an explicitly-passed configuration" do
      config = StandardAudit::Configuration.new
      config.sensitive_keys = %i[only_this]

      expect(described_class.call({ only_this: 1, password: 2 }, config: config)).to eq(password: 2)
    end
  end

  describe "#filter?" do
    it "answers per key without writing a row" do
      filter = described_class.new

      expect(filter.filter?(:password)).to be(true)
      expect(filter.filter?("password")).to be(true)
      expect(filter.filter?(:input_tokens)).to be(false)
      expect(filter.filter?(:_tags)).to be(false)
    end
  end

  # -- Parity between the two write paths --------------------------------------

  describe "StandardAudit.record" do
    it_behaves_like "an audit metadata write path" do
      def write_metadata(metadata)
        StandardAudit.record("audit.filter.test", metadata: metadata)
      end
    end
  end

  describe "StandardAudit::Subscriber" do
    let(:subscriber) { StandardAudit::Subscriber.new }

    before do
      StandardAudit.config.subscribe_to "audit.filter.test"
      subscriber.setup!
    end

    after { subscriber.teardown! }

    it_behaves_like "an audit metadata write path" do
      def write_metadata(metadata)
        ActiveSupport::Notifications.instrument("audit.filter.test", metadata)
        StandardAudit::AuditLog.last
      end
    end
  end
end
