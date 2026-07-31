# Enumeration shape 1: a shared base includes the contract ONCE, and the real
# operations are its subclasses (jumpdrive-web / fundbright-web / luminality-web
# / nutripod-web all look like this).
#
# It declares nothing and has subclasses, so StandardAudit::Operation::Audit
# excludes it from `.operations` automatically — no host configuration, no
# opt-out list. That auto-exclusion is the whole reason those four apps can
# adopt the contract with a single `include` line.
#
# Note there is deliberately NO lifecycle here: no `call`, no `Result`, no
# `execute`. The gem module contributes the audit contract and nothing else.
class ApplicationOperation
  include StandardAudit::Operation
end
