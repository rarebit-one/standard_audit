require "rails_helper"

RSpec.describe StandardAudit::Operation::Audit do
  # The "undeclared + has subclasses ⇒ it's a base" rule can only see
  # subclasses that are LOADED. Under Zeitwerk's lazy loading a base whose
  # leaves haven't been referenced yet looks childless and would be checked as
  # an operation. That is why the shared-example layer eager-loads by default,
  # and why a host meta-spec must too.
  before(:all) { Rails.application.eager_load! }

  before { StandardAudit.reset_configuration! }
  after { StandardAudit.reset_configuration! }

  # Every predicate takes an explicit `operations:` list, precisely so a host
  # can assert against a hand-built set (and so these specs need no global
  # registry surgery).
  def stub_operation(name, spec)
    Class.new do
      include StandardAudit::Operation

      define_singleton_method(:name) { name }
      case spec
      when :none then audit_none!
      when :abstract then audit_abstract!
      when nil then nil
      else audits(*Array(spec))
      end
    end
  end

  describe ".operations exclusion rules" do
    it "excludes anonymous classes" do
      Class.new { include StandardAudit::Operation }

      expect(described_class.operations).to all(satisfy { |k| !k.name.to_s.empty? })
    end

    it "excludes classes that declared `audit_abstract!`" do
      klass = stub_operation("AbstractStub", :abstract)

      expect(described_class.operations).not_to include(klass)
    end

    # This is the rule that lets four of the five apps adopt the contract with
    # one `include` on their shared base: the base declares nothing and has
    # subclasses, so it drops out with no configuration.
    it "excludes an undeclared class that has subclasses (a shared base)" do
      expect(described_class.operations).not_to include(ApplicationOperation)
      expect(described_class.operations).to include(Orders::CreateOperation)
    end

    # The converse matters just as much: subclassing a real operation must not
    # quietly remove it from the check.
    it "keeps a DECLARED class even when it is subclassed" do
      parent = stub_operation("DeclaredParentStub", "order.created")
      Class.new(parent) { def self.name = "DeclaredChildStub" }

      expect(described_class.operations).to include(parent)
    end

    it "scopes by source path" do
      names = described_class.operations(source: "/spec/dummy/app/operations/").map(&:name)

      expect(names).to include("Orders::CreateOperation", "StandaloneOperation")
      expect(names).not_to include("DeclaredParentStub")
    end
  end

  describe ".catalogue" do
    it "is nil when unconfigured, which skips every membership check" do
      expect(described_class.catalogue).to be_nil
    end

    it "resolves a callable lazily, so an autoloadable constant can be reloaded" do
      calls = 0
      StandardAudit.configure { |c| c.audit_catalogue = -> { calls += 1; %w[a.b] } }

      described_class.catalogue
      described_class.catalogue

      expect(calls).to eq(2)
    end

    it "coerces entries to Strings" do
      StandardAudit.configure { |c| c.audit_catalogue = -> { [:"a.b"] } }

      expect(described_class.catalogue).to eq(%w[a.b])
    end

    it "treats a callable returning nil as no catalogue" do
      StandardAudit.configure { |c| c.audit_catalogue = -> { } }

      expect(described_class.catalogue).to be_nil
    end
  end

  describe ".undeclared" do
    it "returns only the classes with no declaration" do
      undeclared = stub_operation("UndeclaredStub", nil)
      declared = stub_operation("DeclaredStub", "a.b")
      none = stub_operation("NoneStub", :none)

      expect(described_class.undeclared(operations: [undeclared, declared, none]))
        .to eq([undeclared])
    end
  end

  describe ".unknown_actions" do
    let(:klass) { stub_operation("UnknownStub", %w[a.b c.d]) }

    it "reports actions absent from the catalogue, per class" do
      StandardAudit.configure { |c| c.audit_catalogue = -> { %w[a.b] } }

      expect(described_class.unknown_actions(operations: [klass])).to eq(klass => %w[c.d])
    end

    it "is empty when no catalogue is configured" do
      expect(described_class.unknown_actions(operations: [klass])).to eq({})
    end
  end

  describe ".orphan_actions" do
    let(:klass) { stub_operation("OrphanStub", %w[a.b]) }

    it "reports catalogue entries no operation declares" do
      StandardAudit.configure { |c| c.audit_catalogue = -> { %w[a.b dead.entry] } }

      expect(described_class.orphan_actions(operations: [klass])).to eq(%w[dead.entry])
    end

    # A host whose catalogue also covers non-operation writers passes the
    # operation-only slice, or every service action looks orphaned.
    it "checks only the `within:` slice when given" do
      StandardAudit.configure { |c| c.audit_catalogue = -> { %w[a.b service.only] } }

      expect(described_class.orphan_actions(operations: [klass], within: %w[a.b])).to be_empty
    end

    it "is empty when no catalogue and no slice is given" do
      expect(described_class.orphan_actions(operations: [klass])).to eq([])
    end
  end

  describe ".duplicate_catalogue_entries" do
    it "finds repeats" do
      StandardAudit.configure { |c| c.audit_catalogue = -> { %w[a.b a.b c.d] } }

      expect(described_class.duplicate_catalogue_entries).to eq(%w[a.b])
    end
  end

  describe ".missing_write_sites" do
    it "flags an operation that declares `audits` but never calls audit!" do
      expect(described_class.missing_write_sites(operations: [SilentOperation]))
        .to eq([SilentOperation])
    end

    it "does not flag an operation that declares and writes, or one declaring `audit_none!`" do
      operations = [Orders::CreateOperation, Orders::ReindexOperation]

      expect(described_class.missing_write_sites(operations: operations)).to be_empty
    end

    it "matches a paren-less call site too" do
      # Orders::ExportReportOperation uses `audit! "order.exported", ...`
      expect(described_class.missing_write_sites(operations: [Orders::ExportReportOperation]))
        .to be_empty
    end

    it "skips classes whose source cannot be read" do
      expect(described_class.missing_write_sites(operations: [stub_operation("Ghost", "a.b")]))
        .to be_empty
    end
  end

  describe ".unexpected_write_sites" do
    # Catches statically what the runtime guard only catches if the path is
    # actually exercised.
    it "flags an `audit_none!` operation that calls audit! anyway" do
      expect(described_class.unexpected_write_sites(operations: [LeakyOperation]))
        .to eq([LeakyOperation])
    end

    it "is empty for a clean `audit_none!` operation" do
      expect(described_class.unexpected_write_sites(operations: [Orders::ReindexOperation]))
        .to be_empty
    end

    # Regression: until 0.9.1 the scan read raw source, so an `audit_none!`
    # operation that *explained itself* in prose naming the write path was
    # flagged. Hosts worked around it by backticking the token in their own
    # comments — the gem dictating comment style to appease a static check.
    it "does not flag a documented `audit_none!` operation whose comments name audit!" do
      expect(described_class.unexpected_write_sites(operations: [DocumentedNoneOperation]))
        .to be_empty
    end
  end

  describe ".strip_comments (via the write-site scan)" do
    # The naive fix — deleting `#` to end-of-line — would trade this false
    # failure for a false pass by eating `"#{interpolation}"` and `%w[#]`.
    # DocumentedNoneOperation contains both, so a broken stripper corrupts its
    # source and the example above stops meaning what it claims.
    it "leaves interpolation and percent-literals intact" do
      stripped = described_class.send(:source_for, DocumentedNoneOperation)

      expect(stripped).to include('"#{name} deleted"')
      expect(stripped).to include("%w[# ok]")
      expect(stripped).not_to include("no direct")
    end

    it "falls back to raw source rather than raising when a file cannot be lexed" do
      expect(described_class.send(:strip_comments, "def broken(")).to eq("def broken(")
    end
  end

  describe ".declared_actions" do
    it "unions and de-duplicates" do
      a = stub_operation("UnionA", %w[x.y])
      b = stub_operation("UnionB", %w[x.y z.w])

      expect(described_class.declared_actions(operations: [a, b])).to eq(%w[x.y z.w])
    end
  end
end
