# Fixture for spec/lib/standard_audit/rspec/coverage_spec.rb. Not loaded as a
# spec (no _spec.rb suffix); the coverage scan reads it as text.
expect { create_order }.to have_audited("order.created")
expect { noop }.not_to have_audited("order.refunded")
