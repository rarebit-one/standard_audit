require "rails_helper"
require "tmpdir"
require "standard_audit/rspec/coverage"

RSpec.describe StandardAudit::RSpec::Coverage do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  def write_spec(name, body)
    path = File.join(@root, "spec", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def report(**options)
    described_class.report(root: @root, **options)
  end

  describe ".covered_actions" do
    it "finds positive literal assertions with their location" do
      write_spec("orders_spec.rb", <<~RUBY)
        it "creates" do
          expect { create_order }.to have_audited("order.created").once
        end
        it "ships" do
          expect { ship }
            .to(have_audited('order.shipped'))
            .and have_audited("order.notified")
        end
      RUBY

      covered = described_class.covered_actions(root: @root)

      expect(covered.keys).to contain_exactly("order.created", "order.shipped", "order.notified")
      expect(covered["order.created"]).to eq(["spec/orders_spec.rb:2"])
    end

    it "ignores negated and dynamic assertions" do
      write_spec("noop_spec.rb", <<~RUBY)
        expect { noop }.not_to have_audited("order.created")
        expect { noop }.to_not have_audited("order.cancelled")
        expect { run }.to have_audited("order.\#{kind}")
        expect { run }.to have_audited(AuditCatalogue::ORDER_CREATED)
          # expect { create_order }.to have_audited("order.commented_out")
      RUBY

      expect(described_class.covered_actions(root: @root)).to be_empty
    end
  end

  describe ".report" do
    before do
      write_spec("orders_spec.rb", <<~RUBY)
        expect { a }.to have_audited("order.created")
        expect { b }.to have_audited("auth.token_invalid")
      RUBY
    end

    it "is ok when every catalogue action is covered or pending" do
      result = report(catalogue: %w[order.created order.refunded], pending: %w[order.refunded])

      expect(result).to be_ok
      expect(result.uncovered).to be_empty
    end

    it "lists uncovered catalogue actions" do
      result = report(catalogue: -> { %w[order.created order.refunded] })

      expect(result).not_to be_ok
      expect(result.uncovered).to eq(["order.refunded"])
    end

    it "flags pending actions outside the catalogue and pending actions that are covered" do
      result = report(catalogue: %w[order.created], pending: %w[order.created order.ghost])

      expect(result.unknown_pending).to eq(["order.ghost"])
      expect(result.stale_pending).to eq(["order.created"])
    end

    it "does not require assertions outside the catalogue to be catalogued" do
      expect(report(catalogue: %w[order.created])).to be_ok
    end

    it "defaults the catalogue to config.audit_catalogue" do
      StandardAudit.config.audit_catalogue = -> { %w[order.created order.refunded] }

      expect(report.uncovered).to eq(["order.refunded"])
    ensure
      StandardAudit.config.audit_catalogue = nil
    end
  end

  describe "the shared example" do
    gem_root = File.expand_path("../../../..", __dir__)

    before { StandardAudit.config.audit_catalogue = %w[order.created order.refunded] }

    after { StandardAudit.config.audit_catalogue = nil }

    it_behaves_like "standard_audit catalogue coverage",
      pending: %w[order.refunded],
      specs: "spec/fixtures/coverage/*.rb",
      root: gem_root
  end
end
