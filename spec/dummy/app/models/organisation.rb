class Organisation < ApplicationRecord
  include GlobalID::Identification
  include StandardAudit::AuditScope
end
