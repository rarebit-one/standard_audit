module Orders
  class ReindexOperation < ApplicationOperation
    # Projection derived from already-audited state — the create/update that
    # changed the order is audited, so re-deriving the index adds no record.
    audit_none!

    def execute
      :reindexed
    end
  end
end
