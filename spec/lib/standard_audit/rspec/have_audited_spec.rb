require "rails_helper"
require "standard_audit/rspec/matchers"

RSpec.describe StandardAudit::RSpec::Matchers::HaveAudited do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:other) { User.create!(name: "Bob", email: "bob@example.com") }
  let(:order) { Order.create!(total: 5) }
  let(:org) { Organisation.create!(name: "Acme") }

  before { StandardAudit.reset_configuration!(replay_baseline: false) }

  def audit(event = "order.created", **attrs)
    StandardAudit.record(event, actor: user, target: order, scope: org, metadata: { total: 5, tags: %w[a b] }, **attrs)
  end

  it "passes when the block writes a matching row" do
    expect { audit }.to have_audited("order.created").by(user).on(order).within(org).with_metadata(total: 5)
  end

  it "accepts RSpec matchers for references and metadata values" do
    expect { audit }.to have_audited("order.created")
      .by(an_instance_of(User)).with_metadata("tags" => include("a"), total: a_value > 1)
  end

  it "treats a bare .by / .on as 'a resolvable GlobalID is present'" do
    expect { audit }.to have_audited("order.created").by.on.within
    expect { StandardAudit.record("order.created") }.not_to have_audited("order.created").by
  end

  it "ignores rows written before the block" do
    audit

    expect { nil }.not_to have_audited("order.created")
  end

  it "counts with .once and .times" do
    expect { audit }.to have_audited("order.created").once
    expect { 2.times { audit } }.to have_audited("order.created").times(2)
    expect {
      expect { 2.times { audit } }.to have_audited("order.created").once
    }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /2 matching row\(s\)/)
  end

  it "rejects a count under not_to" do
    expect {
      expect { audit }.not_to have_audited("order.created").once
    }.to raise_error(ArgumentError, /not supported with not_to/)
  end

  it "fails with the rows it did see when nothing matches" do
    expect {
      expect { audit }.to have_audited("order.created").by(other)
    }.to raise_error(RSpec::Expectations::ExpectationNotMetError) { |error|
      expect(error.message).to include(
        "have audited \"order.created\" by #{other.to_global_id}",
        "actor=#{user.to_global_id.to_s.inspect}"
      )
    }
  end

  it "names the event types that were written instead" do
    expect {
      expect { audit("order.updated") }.to have_audited("order.created")
    }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /it wrote only: order\.updated/)
  end

  it "fails the negation with the offending rows" do
    expect {
      expect { audit }.not_to have_audited("order.created")
    }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /not to have audited "order.created", but it wrote/)
  end

  it "fails on a metadata mismatch" do
    expect {
      expect { audit }.to have_audited("order.created").with_metadata(total: 6)
    }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /no "order.created" row matched/)
  end
end
