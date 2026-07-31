# Fixture: declares `audit_none!` yet calls the write path anyway, so
# `unexpected_write_sites` must flag it. See silent_operation.rb for why each
# fixture gets its own file.
class LeakyOperation
  include StandardAudit::Operation

  audit_none!

  def execute
    audit!("order.created")
  end
end
