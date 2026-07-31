require "rails_helper"
require "standard_audit/rspec/operation"

# The shared-example layer, run against the dummy app — which deliberately
# contains BOTH adoption shapes at once:
#
#   - ApplicationOperation includes the module and its subclasses are the real
#     operations (jumpdrive-web / fundbright-web / luminality-web / nutripod-web)
#   - StandaloneOperation includes the module directly, with no base at all
#     (sidekick-web)
#
# plus an `audit_abstract!` intermediate (Orders::BaseReportOperation) with a
# declaring leaf under it.
RSpec.describe "Operation audit declarations" do
  before do
    StandardAudit.configure { |c| c.audit_catalogue = -> { AuditCatalogue::ACTIONS } }
  end

  after { StandardAudit.reset_configuration! }

  it_behaves_like "standard_audit operation declarations",
    source: "/spec/dummy/app/operations/",
    minimum: 4,
    expected: %w[Orders::CreateOperation StandaloneOperation],
    orphans_within: -> { AuditCatalogue::OPERATION_ACTIONS }

  # The `minimum:` floor is the example that catches "someone stopped including
  # the module". Every other example in the group passes against an empty set,
  # so without it a total wiring failure is green.
  describe "the registry floor" do
    # Builds and runs a throwaway example group, then unregisters it so the
    # outer suite doesn't run it a second time and inherit its (deliberate)
    # failure.
    def run_group(**options)
      group = RSpec.describe("negative control") do
        include_examples "standard_audit operation declarations", **options
      end
      RSpec.world.example_groups.delete(group)
      group.run(RSpec::Core::NullReporter)
    end

    it "fails when the registry has fewer operations than the floor" do
      expect(run_group(source: "/no/such/path/", minimum: 4)).to be(false)
    end

    # The negative control for the negative control: without a floor, a total
    # wiring failure — nothing registered at all — is GREEN. That is precisely
    # the hole `minimum:` exists to close.
    it "passes the same group when no floor is declared (the vacuous case)" do
      expect(run_group(source: "/no/such/path/")).to be(true)
    end
  end
end
