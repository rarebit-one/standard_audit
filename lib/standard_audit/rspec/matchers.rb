require "standard_audit"

# Block matcher asserting that a block wrote an audit row.
#
#   require "standard_audit/rspec/matchers"   # or "standard_audit/rspec"
#
#   expect { operation.call }
#     .to have_audited("order.created")
#     .by(account)                  # actor: a record, an RSpec matcher, or no arg for "any actor"
#     .on(order)                    # target: same forms
#     .within(organisation)         # scope: same forms
#     .with_metadata(total: 100)    # subset match; values may be RSpec matchers
#     .once                         # or .times(n); default is "at least one"
#
#   expect { noop }.not_to have_audited("order.created")
#
# Only rows written DURING the block are considered, and only persisted ones:
# under `config.async = true` run jobs inline (or use `perform_enqueued_jobs`),
# and a `StandardAudit.batch` must be flushed inside the block.
#
# `.by` / `.on` / `.within` with no argument assert presence — a well-formed
# row with a resolvable GlobalID — which is what per-app helpers such as
# `expect_well_formed_audit` checked by hand.
module StandardAudit
  module RSpec
    module Matchers
      class HaveAudited
        include ::RSpec::Matchers::Composable

        ANY = Object.new.freeze
        private_constant :ANY

        def initialize(event_type)
          @event_type = event_type.to_s
          @references = {}
          @metadata = nil
          @count = nil
        end

        def by(actor = ANY)
          @references[:actor] = actor
          self
        end

        def on(target = ANY)
          @references[:target] = target
          self
        end

        def within(scope = ANY)
          @references[:scope] = scope
          self
        end
        alias_method :scoped_to, :within

        def with_metadata(expected)
          @metadata = expected.to_h.deep_stringify_keys
          self
        end

        def once
          times(1)
        end

        def times(count)
          @count = count
          self
        end
        alias_method :exactly, :times

        def supports_block_expectations?
          true
        end

        def supports_value_expectations?
          false
        end

        def matches?(block)
          capture(block)
          @count ? matching.size == @count : matching.any?
        end

        def does_not_match?(block)
          raise ArgumentError, "have_audited(...).times/once is not supported with not_to" if @count

          capture(block)
          matching.empty?
        end

        def description
          parts = ["have audited #{@event_type.inspect}"]
          @references.each { |role, value| parts << "#{preposition(role)} #{describe_value(value)}" }
          parts << "with metadata including #{@metadata.inspect}" if @metadata
          parts << (@count == 1 ? "once" : "#{@count} times") if @count
          parts.join(" ")
        end

        def failure_message
          "expected block to #{description}, but #{found_summary}"
        end

        def failure_message_when_negated
          "expected block not to #{description}, but it wrote:\n#{format_rows(matching)}"
        end

        private

        def capture(block)
          before_ids = StandardAudit::AuditLog.pluck(:id)
          block.call
          @written = StandardAudit::AuditLog.where.not(id: before_ids).order(:created_at, :id).to_a
          @candidates = @written.select { |log| log.event_type == @event_type }
        end

        def matching
          @matching ||= @candidates.select { |log| row_matches?(log) }
        end

        def row_matches?(log)
          @references.all? { |role, expected| reference_matches?(log, role, expected) } &&
            metadata_matches?(log.metadata || {})
        end

        def metadata_matches?(actual)
          return true if @metadata.nil?

          @metadata.all? { |key, value| actual.key?(key) && values_match?(value, actual[key]) }
        end

        def reference_matches?(log, role, expected)
          gid = log.public_send(:"#{role}_gid")

          if expected.equal?(ANY)
            gid.present? && GlobalID.parse(gid)&.model_id.present?
          elsif expected.respond_to?(:to_global_id) && !matcher?(expected)
            gid == expected.to_global_id.to_s
          else
            values_match?(expected, log.public_send(role))
          end
        end

        def matcher?(object)
          ::RSpec::Matchers.is_a_matcher?(object)
        end

        def preposition(role)
          { actor: "by", target: "on", scope: "within" }.fetch(role)
        end

        def describe_value(value)
          return "any record" if value.equal?(ANY)
          return value.description if matcher?(value) && value.respond_to?(:description)
          return value.to_global_id.to_s if value.respond_to?(:to_global_id)

          value.inspect
        end

        def found_summary
          if @candidates.empty?
            others = @written.map(&:event_type).uniq
            others.empty? ? "no audit rows were written" : "it wrote only: #{others.join(", ")}"
          elsif @count
            "#{matching.size} matching row(s) were written:\n#{format_rows(@candidates)}"
          else
            "no #{@event_type.inspect} row matched. Rows written:\n#{format_rows(@candidates)}"
          end
        end

        def format_rows(rows)
          rows.map { |log|
            "  #{log.event_type} actor=#{log.actor_gid.inspect} target=#{log.target_gid.inspect} " \
              "scope=#{log.scope_gid.inspect} metadata=#{log.metadata.inspect}"
          }.join("\n")
        end
      end

      def have_audited(event_type)
        HaveAudited.new(event_type)
      end
    end
  end
end

RSpec.configure do |config|
  config.include StandardAudit::RSpec::Matchers
end
