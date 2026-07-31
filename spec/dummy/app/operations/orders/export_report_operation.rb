module Orders
  class ExportReportOperation < BaseReportOperation
    audits "order.exported"

    def initialize(order)
      @order = order
    end

    def execute
      audit! "order.exported", target: @order
    end
  end
end
