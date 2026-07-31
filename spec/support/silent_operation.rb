# Fixture for the source-scanning predicates: it declares `audits` but has no
# write call site, so `missing_write_sites` must flag it. Deliberately NOT
# under spec/dummy/app/operations/, so the dummy app's meta-spec (which scopes
# by source path) stays green.
#
# One class per file, deliberately: the scan reads the whole defining file, so
# two operations sharing a file would share a verdict. Zeitwerk requires
# one-class-per-file in a real app, so this only bites in fixtures.
class SilentOperation
  include StandardAudit::Operation

  audits "order.created"

  def execute
    :nothing_recorded
  end
end
