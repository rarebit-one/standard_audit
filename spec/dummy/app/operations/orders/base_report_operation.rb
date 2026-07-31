module Orders
  # An INTERMEDIATE class between the base and the leaves. It would be caught by
  # the automatic "declares nothing and has subclasses" rule too, but stating it
  # explicitly is the documented form — and it is the only thing that works for
  # an intermediate that has no subclasses yet.
  class BaseReportOperation < ApplicationOperation
    audit_abstract!

    def execute
      raise NotImplementedError
    end
  end
end
