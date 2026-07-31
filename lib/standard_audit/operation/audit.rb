require "ripper"

module StandardAudit
  module Operation
    # The registry, the catalogue resolver, the write-error policy, and the
    # analysis predicates behind the operation-audit meta-spec.
    #
    # Everything here is PLAIN RUBY that returns data — no RSpec, no
    # assertions. A host can call these from a bespoke spec, a rake task, or a
    # CI script. `standard_audit/rspec/operation` is a thin shared-example
    # layer over exactly these methods and adds no logic of its own.
    #
    #   StandardAudit::Operation::Audit.undeclared           # => [Class, ...]
    #   StandardAudit::Operation::Audit.unknown_actions      # => { Class => ["x.y"] }
    #   StandardAudit::Operation::Audit.orphan_actions       # => ["x.y"]
    #   StandardAudit::Operation::Audit.missing_write_sites  # => [Class, ...]
    module Audit
      # Heuristic used by the source-scanning predicates: a call to the private
      # `audit!` helper, with or without parentheses, not preceded by a receiver
      # (so `foo.audit!` and `Something::audit!` don't count).
      #
      # The scan is FILE-scoped, not class-scoped — two operations defined in
      # one file share a verdict. Zeitwerk requires one class per file in a
      # real app, so this only matters for fixtures.
      #
      # Comments are stripped before scanning (see .strip_comments), so a
      # documented or commented-out `audit!` is not a write site. Until 0.9.1
      # it was, and the docstring here claimed the predicates "err towards a
      # false pass rather than a false failure" — which was only ever true of
      # {.missing_write_sites}. In the {.unexpected_write_sites} direction the
      # same match produces a false FAILURE, so an `audit_none!` class that
      # explained itself in prose failed the check. The claim was wrong for
      # half its own surface, which is worse than the bug: it told anyone
      # hitting the failure not to suspect the scanner.
      #
      # What remains genuinely heuristic: a string literal containing `audit!`
      # still counts, and the runtime guard is still the authoritative check.
      WRITE_SITE_PATTERN = /(?<![\w.:])audit!\s*(?:\(|["':@$\w])/

      class << self
        # ── Registry ────────────────────────────────────────────────────────

        # Every class that has gained the contract, in registration order.
        # Includes bases, intermediates, and anonymous classes — use
        # {.operations} for the filtered view a meta-spec should assert on.
        def registered
          @registered ||= []
        end

        def register(klass)
          registered << klass unless registered.include?(klass)
          klass
        end

        # Empties the registry. For the gem's own specs and for hosts that
        # rebuild the constant graph mid-suite; a normal suite never needs it.
        def reset_registry!
          @registered = []
        end

        # The real operations a meta-spec should hold to the contract.
        #
        # Excluded:
        #   - anonymous classes (no name) — test doubles and `Class.new` fixtures
        #   - classes that declared `audit_abstract!`
        #   - classes that declare NOTHING and have subclasses — i.e. a shared
        #     base such as `ApplicationOperation`. This is what lets an app
        #     adopt the whole contract with one `include` on its base class and
        #     no further configuration. A class that DID declare is never
        #     excluded by this rule, even if it is subclassed, so subclassing a
        #     real operation cannot quietly drop it from the check.
        #
        # @param source [String, nil] keep only classes whose defining file path
        #   contains this fragment, e.g. `"/app/operations/"`. Recommended: it
        #   scopes the check to the host's own operations and drops anything
        #   defined in a spec file.
        def operations(source: nil)
          registered.select do |klass|
            next false if klass.name.nil? || klass.name.empty?
            next false if klass.audit_spec == :abstract
            next false if klass.audit_spec.nil? && subclassed?(klass)
            next true if source.nil?

            source_path(klass)&.include?(source)
          end
        end

        # Absolute path of the file that defines `klass`, or nil.
        def source_path(klass)
          return nil if klass.name.nil? || klass.name.empty?

          Object.const_source_location(klass.name)&.first
        rescue NameError
          nil
        end

        # ── Catalogue ───────────────────────────────────────────────────────

        # The host's action vocabulary as an Array of Strings, or nil when no
        # catalogue is configured (in which case membership is not checked).
        #
        # `config.audit_catalogue` is normally a callable — see the note in
        # StandardAudit::Operation on why an eagerly-referenced autoloadable
        # constant breaks Zeitwerk reloading. A plain Array is accepted for the
        # case where the vocabulary really is a frozen literal.
        def catalogue
          raw = StandardAudit.config.audit_catalogue
          return nil if raw.nil?

          resolved = raw.respond_to?(:call) ? raw.call : raw
          return nil if resolved.nil?

          Array(resolved).map(&:to_s)
        end

        # ── Policy ──────────────────────────────────────────────────────────

        # Whether `audit!` verifies declarations before writing. Defaults to
        # "local environments only" — production writes silently, because a
        # developer's declaration mistake must not 500 a user.
        def verify?
          resolver = StandardAudit.config.verify_audit_declarations
          resolver.respond_to?(:call) ? !!resolver.call : !!resolver
        end

        # Applies the configured policy to a failed audit *write* (never to a
        # DeclarationError, which `audit!` re-raises first).
        #
        # @return [nil] when the error is swallowed
        # @raise [StandardError] the original error when
        #   `config.raise_on_audit_write_error` is true
        def handle_write_error(error, action:, operation:)
          handler = StandardAudit.config.audit_write_error_handler

          if handler
            handler.call(error, action: action, operation: operation)
          else
            report_write_error(error, action: action, operation: operation)
          end

          raise error if StandardAudit.config.raise_on_audit_write_error

          nil
        end

        # ── Predicates ──────────────────────────────────────────────────────

        # Operations that declare neither `audits` nor `audit_none!`. A new
        # mutating operation shipping with no audit trail shows up here.
        #
        # @return [Array<Class>]
        def undeclared(operations: self.operations)
          operations.select { |klass| klass.audit_spec.nil? }
        end

        # Declared actions that are absent from the configured catalogue.
        # Empty when no catalogue is configured.
        #
        # @return [Hash{Class => Array<String>}]
        def unknown_actions(operations: self.operations, catalogue: self.catalogue)
          return {} if catalogue.nil?

          operations.each_with_object({}) do |klass, acc|
            unknown = declared_for(klass) - catalogue
            acc[klass] = unknown if unknown.any?
          end
        end

        # Catalogue entries no operation declares — dead vocabulary, which makes
        # the catalogue a wish rather than a record.
        #
        # @param within [Array<String>, nil] check only this slice. Hosts whose
        #   catalogue also covers non-operation writers (a controller concern, a
        #   tool server, a notification-bus name) pass the operation-only slice
        #   here; the rest are written outside `app/operations/` and would
        #   always look orphaned.
        # @return [Array<String>]
        def orphan_actions(operations: self.operations, catalogue: self.catalogue, within: nil)
          pool = within ? Array(within).map(&:to_s) : catalogue
          return [] if pool.nil?

          pool - declared_actions(operations: operations)
        end

        # Every action declared across the given operations, de-duplicated.
        #
        # @return [Array<String>]
        def declared_actions(operations: self.operations)
          operations.flat_map { |klass| declared_for(klass) }.uniq
        end

        # Catalogue entries listed more than once.
        #
        # @return [Array<String>]
        def duplicate_catalogue_entries(catalogue: self.catalogue)
          return [] if catalogue.nil?

          catalogue.tally.select { |_action, count| count > 1 }.keys
        end

        # Operations that declare `audits` but whose source contains no `audit!`
        # call — the declaration is aspirational and nothing writes the row.
        #
        # Source-based, therefore a heuristic: a class whose defining file can't
        # be read is skipped rather than reported.
        #
        # @return [Array<Class>]
        def missing_write_sites(operations: self.operations)
          operations.select do |klass|
            spec = klass.audit_spec
            next false unless spec.is_a?(Array)

            src = source_for(klass)
            src && !src.match?(WRITE_SITE_PATTERN)
          end
        end

        # Operations that declare `audit_none!` but whose source calls `audit!`
        # anyway. The runtime guard catches this too, but only if that code path
        # is exercised; this catches it statically.
        #
        # @return [Array<Class>]
        def unexpected_write_sites(operations: self.operations)
          operations.select do |klass|
            next false unless klass.audit_spec == :none

            src = source_for(klass)
            src&.match?(WRITE_SITE_PATTERN)
          end
        end

        private

        def declared_for(klass)
          spec = klass.audit_spec
          spec.is_a?(Array) ? spec : []
        end

        def source_for(klass)
          path = source_path(klass)
          return nil unless path && File.exist?(path)

          strip_comments(File.read(path))
        end

        # Comments are not write sites. Scanning raw source made a class that
        # declares `audit_none!` and *explains why* in prose ("No direct audit!
        # here") fail `unexpected_write_sites` — the scanner matched the word in
        # the comment. That is a false failure, and it forced hosts to backtick
        # the token in their own comments to appease a static check.
        #
        # Lexing rather than regex-stripping `#` to end-of-line, because the
        # naive form eats `"#{interpolation}"` and `%w[#]`, which would trade a
        # false failure for a false pass. A file Ripper cannot lex (syntax the
        # running Ruby doesn't accept) falls back to the raw source: the old
        # behaviour, which is conservative in the `audits` direction.
        def strip_comments(src)
          tokens = Ripper.lex(src)
          return src if tokens.nil?

          tokens.reject { |(_pos, type, _tok, _state)| type == :on_comment }
                .map { |(_pos, _type, tok, _state)| tok }
                .join
        rescue StandardError
          src
        end

        def subclassed?(klass)
          klass.respond_to?(:subclasses) && klass.subclasses.any?
        end

        def report_write_error(error, action:, operation:)
          message = "[StandardAudit] Failed to record #{action}: #{error.class} #{error.message}"
          Rails.logger&.error(message) if defined?(Rails) && Rails.respond_to?(:logger)

          return unless defined?(Rails) && Rails.respond_to?(:error) && Rails.error

          Rails.error.report(
            error,
            handled: true,
            context: { audit_action: action, operation: operation.class.name }
          )
        end
      end
    end
  end
end
