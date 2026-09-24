module StandardAudit
  module Checksum
    # Reconstructs the key order a version-1 row was signed with.
    #
    # A version-1 digest covers `metadata.to_json` in the writer's Ruby
    # insertion order. A `jsonb` column has since discarded that order, and it
    # cannot be derived from the stored row: the storage order is a function
    # of the key set alone, so every insertion order maps to the same stored
    # value. What CAN be done is to try the orders. If some ordering of the
    # stored keys, hashed with the row's own parent, reproduces the digest the
    # row has held since it was written, that is a witness in the same sense
    # as the parent recovery search: SHA-256 preimage resistance means a row
    # whose values were altered reproduces no ordering. Trying N orderings
    # costs log2(N) bits of a 256-bit margin.
    #
    # The search is bounded. The number of orderings is the product of `n!`
    # over every object in the value, so it is only enumerated in full when
    # that product is at most `limit`. Orders that reproduced an earlier row
    # with the same key structure are remembered and tried first, because a
    # given event is almost always built by the same code path in the same
    # order — that is what makes the search cheap across a whole log.
    #
    # One instance lives for one verify_chain walk. It never writes anything.
    class KeyOrderSearch
      DEFAULT_LIMIT = 720 # 6 keys in one object, or e.g. 3 × 3! nested
      REMEMBERED_ORDERS = 8

      attr_reader :limit

      def initialize(limit: DEFAULT_LIMIT)
        @limit = limit.to_i
        @learned = Hash.new { |h, k| h[k] = [] }
      end

      # Searches the orderings of every Hash-valued field in `attrs` for one
      # that reproduces `checksum` under version 1 with one of `parents`.
      # Returns `{ parent:, attrs: }` on a match, nil otherwise.
      def search(attrs, fields:, checksum:, parents:)
        hashed = fields.select { |f| attrs[f].is_a?(Hash) }
        return nil if hashed.empty? || limit <= 0

        signature = hashed.map { |f| [f, self.class.signature(attrs[f])] }

        # Remembered orders first: one try each, however large the object.
        @learned[signature].dup.each do |templates|
          candidate = attrs.merge(hashed.zip(templates).to_h { |f, t| [f, self.class.apply(t, attrs[f])] })
          match = try(candidate, fields, checksum, parents)
          return remember(signature, hashed, candidate, match) if match
        end

        return nil unless exhaustive?(attrs, fields: fields)

        per_field = hashed.map { |f| self.class.variants(attrs[f]) }
        combos = per_field.first.product(*per_field.drop(1))

        combos.each do |values|
          candidate = attrs.merge(hashed.zip(values).to_h)
          match = try(candidate, fields, checksum, parents)
          return remember(signature, hashed, candidate, match) if match
        end

        nil
      end

      # True when `search` enumerates EVERY ordering of this row, so a miss
      # means no key order explains the digest — with a known parent, the row
      # does not match its signed content.
      def exhaustive?(attrs, fields:)
        count = fields.select { |f| attrs[f].is_a?(Hash) }.reduce(1) { |acc, f| acc * self.class.variant_count(attrs[f]) }
        count <= limit
      end

      class << self
        def variant_count(node)
          case node
          when Hash then (1..node.size).reduce(1, :*) * node.each_value.reduce(1) { |acc, v| acc * variant_count(v) }
          when Array then node.reduce(1) { |acc, v| acc * variant_count(v) }
          else 1
          end
        end

        # Every ordering of every object inside `node`. The first is the
        # stored order. Callers bound the size with variant_count.
        def variants(node)
          case node
          when Hash
            keys = node.keys
            children = keys.to_h { |k| [k, variants(node[k])] }
            keys.permutation.flat_map do |perm|
              choices = perm.map { |k| children[k] }
              product(choices).map { |values| perm.zip(values).to_h }
            end
          when Array
            product(node.map { |v| variants(v) })
          else
            [node]
          end
        end

        # The key structure of a value, independent of order.
        def signature(node)
          case node
          when Hash then [:h, node.keys.map(&:to_s).sort.map { |k| [k, signature(node[k])] }]
          when Array then [:a, node.map { |v| signature(v) }]
          end
        end

        # The ordering of `node`, as a template `apply` can replay.
        def template(node)
          case node
          when Hash then [:h, node.map { |k, v| [k, template(v)] }]
          when Array then [:a, node.map { |v| template(v) }]
          end
        end

        def apply(template, node)
          case template&.first
          when :h then template.last.to_h { |k, t| [k, apply(t, node[k])] }
          when :a then node.each_with_index.map { |v, i| apply(template.last[i], v) }
          else node
          end
        end

        private

        def product(lists)
          return [[]] if lists.empty?

          lists.first.product(*lists.drop(1))
        end
      end

      private

      def try(candidate, fields, checksum, parents)
        parents.each do |parent|
          digest = Checksum.legacy_digest(candidate, fields: fields, previous_checksum: parent)
          return { parent: parent } if digest == checksum
        end
        nil
      end

      def remember(signature, hashed, candidate, match)
        templates = hashed.map { |f| self.class.template(candidate[f]) }
        list = @learned[signature]
        list.delete(templates)
        list.unshift(templates)
        list.pop while list.size > REMEMBERED_ORDERS
        match.merge(attrs: candidate)
      end
    end
  end
end
