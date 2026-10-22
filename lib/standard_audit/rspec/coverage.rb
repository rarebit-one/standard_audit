require "standard_audit"

# Catalogue coverage: every catalogue action is asserted by a positive
# `have_audited("…")` somewhere in the suite.
#
#   require "standard_audit/rspec/coverage"
#
#   RSpec.describe "Audit catalogue coverage" do
#     it_behaves_like "standard_audit catalogue coverage",
#       pending: %w[grant.pass_scheduled]   # catalogued, not written yet
#   end
#
# It is a STATIC scan of the spec files, not a runtime tally. Four of the five
# estate apps run their suites under parallel_rspec, where no single process
# sees every example, and a partial run (one file) would always look
# uncovered. A literal `expect { … }.to have_audited("order.created")` in a
# green suite means that example wrote the row, which is what coverage needs.
# Negated assertions (`not_to have_audited`) and commented-out lines do not
# count, and neither do action names built at runtime (interpolated strings,
# constants): list those under `pending:` with a comment, or assert them with
# a literal. The scan is line-based, so an assertion inside a heredoc or string
# would still count; don't keep one there.
#
# This replaces the hand-maintained `CATALOGUE_ACTIONS` copies in
# `spec/support/audit_log_coverage.rb` and the specs that kept them in sync
# with the real catalogue.
#
# Options (all optional):
#
#   catalogue: the actions that must be covered, as an Array or a callable.
#              Defaults to `config.audit_catalogue`. Pass a slice (e.g.
#              `-> { AuditCatalogue::OPERATION_ACTIONS }`) to scope it.
#   pending:   catalogue actions allowed to have no assertion yet. Each must be
#              in the catalogue, and one that gains an assertion must be
#              removed, so the list only ever shrinks.
#   specs:     glob(s) of spec files to scan, relative to Rails.root (or the
#              working directory). Defaults to "spec/**/*_spec.rb".
#   root:      the directory `specs:` is relative to. Defaults to Rails.root.
module StandardAudit
  module RSpec
    module Coverage
      # A positive have_audited with a literal action: `.to have_audited("x")`,
      # `.to(have_audited("x"))`, or a compound `.and have_audited("x")`.
      ASSERTION = /(?:\.to|\.and)\s*\(?\s*have_audited\(\s*(["'])([^"'#\\]+)\1/
      DEFAULT_SPECS = "spec/**/*_spec.rb".freeze

      Report = Struct.new(:catalogue, :covered, :uncovered, :unknown_pending, :stale_pending, keyword_init: true) do
        def ok?
          uncovered.empty? && unknown_pending.empty? && stale_pending.empty?
        end
      end

      module_function

      # action => ["path:line", ...] for every positive literal assertion.
      def covered_actions(specs: DEFAULT_SPECS, root: default_root)
        files = Array(specs).flat_map { |glob| Dir.glob(File.expand_path(glob, root)) }.uniq.sort
        files.each_with_object(Hash.new { |h, k| h[k] = [] }) do |file, covered|
          File.foreach(file).with_index(1) do |line, number|
            next if line.lstrip.start_with?("#")

            line.scan(ASSERTION) { |_quote, action| covered[action] << "#{relative(file, root)}:#{number}" }
          end
        end
      end

      def report(catalogue: nil, pending: [], specs: DEFAULT_SPECS, root: default_root)
        catalogue = resolve(catalogue || StandardAudit.config.audit_catalogue).map(&:to_s).uniq
        pending = resolve(pending).map(&:to_s)
        covered = covered_actions(specs: specs, root: root)

        Report.new(
          catalogue: catalogue,
          covered: covered,
          uncovered: catalogue - pending - covered.keys,
          unknown_pending: pending - catalogue,
          stale_pending: pending & covered.keys
        )
      end

      def resolve(value)
        value = value.call if value.respond_to?(:call)
        Array(value)
      end

      def default_root
        defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      end

      def relative(file, root)
        file.delete_prefix("#{root}/")
      end
    end
  end
end

RSpec.shared_examples "standard_audit catalogue coverage" do |options = {}|
  coverage = StandardAudit::RSpec::Coverage

  let(:coverage_report) do
    coverage.report(
      catalogue: options[:catalogue],
      pending: options.fetch(:pending, []),
      specs: options.fetch(:specs, coverage::DEFAULT_SPECS),
      root: options.fetch(:root) { coverage.default_root }
    )
  end

  it "has a catalogue to check" do
    expect(coverage_report.catalogue).not_to be_empty,
      "No catalogue actions to check. Set config.audit_catalogue or pass `catalogue:`; " \
      "otherwise every other example here passes against an empty set."
  end

  it "asserts every catalogue action with have_audited" do
    expect(coverage_report.uncovered).to be_empty,
      "These catalogue actions have no `expect { … }.to have_audited(\"…\")` in the suite:\n  " \
      "#{coverage_report.uncovered.sort.join("\n  ")}\n" \
      "Add an example that writes each one, or list it under `pending:` with the reason."
  end

  it "lists only catalogue actions as pending" do
    expect(coverage_report.unknown_pending).to be_empty,
      "These `pending:` actions are not in the catalogue: #{coverage_report.unknown_pending.sort.join(", ")}"
  end

  it "has no pending action that is already covered" do
    stale = coverage_report.stale_pending.sort
    expect(stale).to be_empty,
      "These `pending:` actions now have an assertion, so remove them from `pending:`:\n  " \
      "#{stale.map { |a| "#{a} (#{coverage_report.covered[a].first})" }.join("\n  ")}"
  end
end
