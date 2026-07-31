module Orders
  class CreateOperation < ApplicationOperation
    audits "order.created"

    def initialize(order)
      @order = order
    end

    def execute
      audit!("order.created", target: @order, metadata: { total: 100 })
    end
  end
end
