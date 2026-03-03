class Order < ApplicationRecord
  include GlobalID::Identification
  belongs_to :user, optional: true
  belongs_to :organisation, optional: true
end
