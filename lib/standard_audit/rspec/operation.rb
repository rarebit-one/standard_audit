require "standard_audit"

# RSpec shared examples for the operation-audit contract.
#
# A THIN layer over StandardAudit::Operation::Audit — every example below is a
# one-line call to a plain-Ruby predicate plus a failure message. If the shape
# of these examples doesn't fit your app, call the predicates directly from a
# bespoke spec and skip this file; nothing here is load-bearing.
#
#   require "standard_audit/rspec/operation"
#
#   RSpec.describe "Operation audit declarations" do
#     it_behaves_like "standard_audit operation declarations",
#       source:         "/app/operations/",
#       minimum:        100,
#       orphans_within: -> { AuditCatalogue::OPERATION_ACTIONS }
#   end
#
# Options (all optional):
#
#   source:         path fragment scoping the check to your own operations.
#                   Strongly recommended — without it, any class anywhere that
#                   includes the module is held to the contract.
#   minimum:        registry floor. THE MOST IMPORTANT OPTION. Without it, an
#                   app where someone stopped including the module — or where
#                   eager loading silently stopped reaching `app/operations/` —
#                   passes every other example vacuously against an empty set.
#                   Set it just below your real count.
#   expected:       Array of class names that must be registered. A second,
#                   sharper form of the same protection.
#   orphans_within: the catalogue slice operations are responsible for, as an
#                   Array or a callable. Use it when your catalogue also covers
#                   writers outside `app/operations/` (a controller concern, a
#                   tool server, a notification-bus name), which would otherwise
#                   always look orphaned. Omit to skip the orphan check;
#                   pass `:catalogue` to check the whole catalogue.
#   eager_load:     force `Rails.application.eager_load!` first so the registry
#                   is complete regardless of the test env's setting.
#                   Defaults to true.
RSpec.shared_examples "standard_audit operation declarations" do |options = {}|
  source         = options[:source]
  minimum        = options[:minimum]
  expected       = Array(options[:expected])
  orphans_within = options[:orphans_within]
  eager_load     = options.fetch(:eager_load, true)

  audit = StandardAudit::Operation::Audit

  before(:all) do
    Rails.application.eager_load! if eager_load && defined?(Rails) && Rails.application
  end

  let(:operations) { audit.operations(source: source) }

  it "sees the operations it is supposed to check" do
    if expected.any?
      expect(operations.map(&:name)).to include(*expected)
    end

    if minimum
      expect(operations.size).to be >= minimum,
        "Expected at least #{minimum} registered operations#{source ? " under #{source}" : ""}, " \
        "found #{operations.size}. Every other example in this group passes vacuously against " \
        "an empty set, so this is almost certainly a wiring failure — an operation that stopped " \
        "including StandardAudit::Operation, or eager loading no longer reaching them."
    end

    skip("no `minimum:` or `expected:` given — nothing to assert") if minimum.nil? && expected.empty?
  end

  it "requires every operation to declare `audits` or `audit_none!`" do
    undeclared = audit.undeclared(operations: operations)

    expect(undeclared).to be_empty,
      "These operations declare neither `audits` nor `audit_none!`:\n  " \
      "#{undeclared.map(&:name).sort.join("\n  ")}\n" \
      "Add `audits \"some.action\"` if it records an audit, or `audit_none!` " \
      "(with the reason in a comment) if it deliberately doesn't."
  end

  it "only declares actions present in the audit catalogue" do
    unknown = audit.unknown_actions(operations: operations)

    skip("no `config.audit_catalogue` configured") if audit.catalogue.nil?

    expect(unknown).to be_empty,
      "These operations declare audit actions missing from the catalogue " \
      "(add them to it):\n  " \
      "#{unknown.map { |klass, actions| "#{klass.name}: #{actions.inspect}" }.join("\n  ")}"
  end

  it "has no duplicate catalogue entries" do
    skip("no `config.audit_catalogue` configured") if audit.catalogue.nil?

    dupes = audit.duplicate_catalogue_entries

    expect(dupes).to be_empty, "duplicate audit catalogue entries: #{dupes.inspect}"
  end

  it "operations that declare `audits` call `audit!`" do
    missing = audit.missing_write_sites(operations: operations)

    expect(missing).to be_empty,
      "These operations declare `audits` but never call `audit!`:\n  " \
      "#{missing.map(&:name).sort.join("\n  ")}"
  end

  it "operations that declare `audit_none!` do not call `audit!`" do
    writing = audit.unexpected_write_sites(operations: operations)

    expect(writing).to be_empty,
      "These operations declare `audit_none!` but call `audit!`:\n  " \
      "#{writing.map(&:name).sort.join("\n  ")}"
  end

  it "has no catalogued action that no operation writes" do
    skip("no `orphans_within:` given") if orphans_within.nil?

    within =
      if orphans_within == :catalogue
        nil
      elsif orphans_within.respond_to?(:call)
        orphans_within.call
      else
        orphans_within
      end

    skip("no `config.audit_catalogue` configured") if within.nil? && audit.catalogue.nil?

    orphans = audit.orphan_actions(operations: operations, within: within)

    expect(orphans).to be_empty,
      "These catalogued actions are declared by no operation — wire them or " \
      "drop them: #{orphans.inspect}"
  end
end
