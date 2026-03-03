class User < ApplicationRecord
  include GlobalID::Identification
  include StandardAudit::Auditable
end
