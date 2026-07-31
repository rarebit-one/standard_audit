require "active_support/concern"
require "standard_audit/operation/audit"

module StandardAudit
  # Operation-level audit contract, extracted from five independent copies of
  # the same DSL (fundbright-web, jumpdrive-web, luminality-web, nutripod-web,
  # sidekick-web).
  #
  # It is a MODULE, never a base class. The five host `ApplicationOperation`
  # classes range from 61 to 303 lines and diverge deliberately — one of them
  # explicitly refuses a `Result`/`execute` lifecycle, and one app has no shared
  # operation base at all. This module contributes the audit contract and
  # nothing else: no lifecycle, no `call`, no `Result`.
  #
  # It gives an including class:
  #
  #   - a class-level declaration of audit intent — `audits "x.y"` (it records
  #     one or more audit events), `audit_none!` (it intentionally records
  #     none), or `audit_abstract!` (it is a base/intermediate class, not a real
  #     operation). The declaration is meant to be MANDATORY, enforced by the
  #     host's meta-spec — see StandardAudit::Operation::Audit and
  #     `standard_audit/rspec/operation`.
  #
  #   - a single private instance-level write path, `audit!(action, **attrs)`,
  #     which verifies the declaration (dev/test only) and then writes through
  #     StandardAudit.record.
  #
  # ── ADOPTION SHAPES ─────────────────────────────────────────────────────────
  # Both shapes found in the estate work with no host configuration:
  #
  #   1. A shared base includes the module once, and the real operations are its
  #      subclasses. `inherited` registers them. The base itself is excluded
  #      from `Audit.operations` automatically because it declares nothing and
  #      has subclasses.
  #
  #   2. Every operation is a leaf that includes the module directly (no shared
  #      base). `included` registers each one.
  #
  # ── ERROR POLICY ────────────────────────────────────────────────────────────
  # `DeclarationError` ALWAYS propagates — it is a developer mistake caught in
  # dev/test, and letting it decay into a swallowed write or a failure Result
  # would hide drift from CI.
  #
  # A genuine *write* failure is governed by `config.raise_on_audit_write_error`
  # (default `false`, i.e. report and swallow). One of the five apps
  # deliberately lets a failed audit write abort the operation, because for it
  # an unaudited state change is a compliance failure; it sets the flag to
  # `true`. A swallow-only module would have silently downgraded that posture,
  # which is why this is configurable rather than fixed.
  #
  # ── CATALOGUE ───────────────────────────────────────────────────────────────
  # The gem has no knowledge of any host's action vocabulary. The host declares
  # it:
  #
  #   StandardAudit.configure(baseline: true) do |config|
  #     config.audit_catalogue = -> { AuditCatalogue::ACTIONS }
  #   end
  #
  # A CALLABLE, because referencing an autoloadable constant eagerly from an
  # initializer pins the first-loaded copy and breaks Zeitwerk reloading. `nil`
  # (the default) means the catalogue check is skipped entirely, so the DSL is
  # adoptable before an app has a catalogue.
  #
  # Membership is the ONLY rule applied to an action string. There is
  # deliberately no dot-count, case, prefix, or namespace validation: one app's
  # catalogue carries notification-bus names verbatim
  # (`jumpdrive-web.surface.audience_changed`) because the subscriber records
  # the bus name as-is, and normalising them would orphan historical rows.
  module Operation
    extend ActiveSupport::Concern

    # Raised when an operation writes an audit action it didn't declare, wrote
    # despite `audit_none!`, or wrote an action absent from the configured
    # catalogue. Raised in dev/test only (see `config.verify_audit_declarations`)
    # and never rescued by this module.
    class DeclarationError < StandardError; end

    included do |base|
      StandardAudit::Operation::Audit.register(base)
    end

    module ClassMethods
      # Subclasses of an adopting base class are the real operations, so they
      # register too — and they do NOT inherit `@audit_spec`, by design: each
      # leaf states its own intent. A leaf reading `nil` through a declared
      # parent would be the wrong (and silently passing) answer.
      def inherited(subclass)
        super
        StandardAudit::Operation::Audit.register(subclass)
      end

      # The audit action(s) this operation is expected to emit.
      #
      # @return [nil, :none, :abstract, Array<String>]
      #   `nil` — undeclared (the meta-spec forbids this)
      #   `:none` — intentionally records no audit
      #   `:abstract` — not a real operation; excluded from the meta-spec
      #   Array — the catalogue action strings it may write
      def audit_spec
        @audit_spec
      end

      # Declare the audit action(s) this operation emits (primary first; an
      # operation may emit several — conditional or per-item — and all must be
      # listed). The matching write happens via #audit! inside the operation.
      #
      #   audits "order.created"
      #   audits "order.created", "order.line_item_added"
      #
      # Values are coerced to Strings, so Symbols and frozen catalogue
      # constants both work. Calling it twice REPLACES the declaration.
      def audits(*actions)
        actions = actions.flatten.map(&:to_s)
        raise ArgumentError, "`audits` needs at least one action" if actions.empty?

        @audit_spec = actions
      end

      # Declare that this operation mutates state but intentionally records no
      # audit. The accepted reasons, all of which should be left as a comment
      # on the call: delegators that audit downstream, projections/re-indexes
      # derived from already-audited state, outcome-only writes on a record
      # whose creation is already audited, and high-volume telemetry ingestion.
      def audit_none!
        @audit_spec = :none
      end

      # Declare that this class is a base or intermediate class rather than a
      # real operation, so the meta-spec skips it.
      #
      # Usually unnecessary: a class that declares nothing and HAS subclasses is
      # treated as a base automatically, which is what makes a one-line
      # `include StandardAudit::Operation` on a shared `ApplicationOperation`
      # work with no further configuration. Use this when the automatic rule is
      # not enough — most often an intermediate class that has no subclasses
      # *yet*, or one you want to state the intent of explicitly.
      def audit_abstract!
        @audit_spec = :abstract
      end
    end

    private

    # The single audit-write path for operations.
    #
    # Call it INSIDE the operation's own transaction where one is open, so the
    # audit row commits atomically with the state change — this helper opens no
    # transaction of its own. `action` is the StandardAudit `event_type`;
    # keyword args are forwarded straight to StandardAudit.record, so `actor:` /
    # `target:` / `scope:` must be model objects (the gem records their
    # GlobalID), alongside `metadata:` and context overrides such as
    # `ip_address:`.
    #
    # `actor:` defaults to whatever `config.current_actor_resolver` returns, so
    # only operations acting on someone else's behalf need to pass it.
    #
    # In dev/test it raises DeclarationError on declaration↔write drift. In
    # production it just writes: a developer mistake shouldn't 500 a user, and
    # the meta-spec is the CI gate.
    #
    # @return [StandardAudit::AuditLog, nil]
    def audit!(action, **attrs)
      action = action.to_s
      verify_audit_declared!(action) if StandardAudit::Operation::Audit.verify?

      StandardAudit.record(action, **attrs)
    rescue DeclarationError
      # Always propagate a declaration mismatch, ahead of the generic rescue
      # below and regardless of `raise_on_audit_write_error`. It can only be
      # raised when verification is on (dev/test).
      raise
    rescue StandardError => e
      StandardAudit::Operation::Audit.handle_write_error(e, action: action, operation: self)
    end

    # Raises DeclarationError when `action` contradicts the class's declaration
    # or is absent from the configured catalogue. Public-ish by convention (it
    # is private, like `audit!`) but documented because host meta-specs assert
    # on its messages.
    def verify_audit_declared!(action)
      catalogue = StandardAudit::Operation::Audit.catalogue

      case (spec = self.class.audit_spec)
      when nil
        raise DeclarationError,
          "#{self.class} writes audit '#{action}' but declares neither `audits` nor `audit_none!`"
      when :none
        raise DeclarationError,
          "#{self.class} declares `audit_none!` but writes audit '#{action}'"
      when :abstract
        raise DeclarationError,
          "#{self.class} declares `audit_abstract!` but writes audit '#{action}'"
      else
        unless spec.include?(action)
          raise DeclarationError,
            "#{self.class} writes audit '#{action}' not in its declared actions #{spec.inspect}"
        end
        if catalogue && !catalogue.include?(action)
          raise DeclarationError,
            "audit action '#{action}' is not in the configured audit catalogue"
        end
      end
    end
  end
end
